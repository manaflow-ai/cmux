@testable import CmuxNextCloud
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The owner's model credentials for Cloud chats (``CloudAgentCredentials``): the connection the
/// Cloud start chose is read at the chat's start, and a ChatGPT plan token is pushed again to every
/// live agent on that connection about ten minutes before it expires, on the injected clock.
@MainActor
@Suite
struct CloudAgentCredentialRefresherTests {
    nonisolated static let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// This Mac's acpmux as the test drives it: each read answers the next token, expiring an hour later.
    @MainActor
    final class Acpmux {
        var reads = 0
        var fails = false
        var expiry: TimeInterval
        let clock: ManualClock

        init(clock: ManualClock, expiresIn: TimeInterval = 3_600) {
            self.clock = clock
            expiry = CloudAgentCredentialRefresherTests.base.timeIntervalSince1970 + expiresIn
        }

        /// Added to the clock's offset (a test that moves the wall clock alone).
        var wallOffset: TimeInterval = 0
        var now: Date { CloudAgentCredentialRefresherTests.base.addingTimeInterval(Double(clock.now.offset.components.seconds) + wallOffset) }

        func read(_ id: String) throws -> CloudAgentCredential {
            reads += 1
            if fails { throw CloudAgentCredentials.Failure.unavailable(connection: id) }
            // A refreshed token whenever fewer than ten minutes are left on the last one.
            if expiry - now.timeIntervalSince1970 <= 600 { expiry = now.timeIntervalSince1970 + 3_600 }
            return CloudAgentCredential(connectionID: id, family: "codex", kind: CloudAgentCredential.chatGPTPlan,
                                        env: ["CMUX_CHATGPT_ACCESS_TOKEN": "token-\(reads)"], expiresAt: Date(timeIntervalSince1970: expiry))
        }
    }

    /// A wall clock a test moves by hand.
    final class Wall: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        var offset: TimeInterval {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// One machine session's received pushes.
    final class Machine: @unchecked Sendable {
        private let lock = NSLock()
        private var got: [[String: String]] = []
        var answer: CloudAgentCredentialRefresher.PushOutcome = .delivered
        var pushes: [[String: String]] { lock.withLock { got } }

        var push: CloudAgentCredentialRefresher.Push {
            { [self] env in lock.withLock { got.append(env); return answer } }
        }
    }

    private func make(_ clock: ManualClock, _ acpmux: Acpmux) -> CloudAgentCredentialRefresher {
        CloudAgentCredentialRefresher(clock: clock, now: { [clock] in Self.base.addingTimeInterval(Double(clock.now.offset.components.seconds)) },
                                      read: { id in try acpmux.read(id) })
    }

    private func started(_ acpmux: Acpmux) throws -> CloudAgentCredential { try acpmux.read("conn-1") }

    @Test func aChatGPTTokenIsPushedTenMinutesBeforeItExpires() async throws {
        let clock = ManualClock(), acpmux = Acpmux(clock: clock), machine = Machine()
        let refresher = make(clock, acpmux)
        #expect(refresher.track(try started(acpmux), push: machine.push) != nil)
        try await clock.waitForSleeper()
        #expect(clock.sleeperDeadlines == [ManualClock.Instant(offset: .seconds(3_000))], "50 minutes into the hour")
        clock.advance(by: .seconds(2_999))
        #expect(machine.pushes.isEmpty && acpmux.reads == 1)
        clock.advance(by: .seconds(1))
        try await clock.waitForSleeper()
        #expect(machine.pushes == [["CMUX_CHATGPT_ACCESS_TOKEN": "token-2"]])
        // The next one 50 minutes into the new token's hour.
        #expect(clock.sleeperDeadlines == [ManualClock.Instant(offset: .seconds(3_000 + 3_000))])
    }

    @Test func oneReadServesEveryAgentOnTheConnection() async throws {
        let clock = ManualClock(), acpmux = Acpmux(clock: clock), first = Machine(), second = Machine()
        let refresher = make(clock, acpmux)
        let credential = try started(acpmux)
        refresher.track(credential, push: first.push)
        refresher.track(credential, push: second.push)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(3_000))
        try await clock.waitForSleeper()
        #expect(acpmux.reads == 2, "one read for both")
        #expect(first.pushes.count == 1 && second.pushes.count == 1)
        #expect(first.pushes == second.pushes)
    }

    @Test func aTokenThatDoesNotExpireIsNotTracked() {
        let clock = ManualClock(), acpmux = Acpmux(clock: clock)
        let refresher = make(clock, acpmux)
        let claude = CloudAgentCredential(connectionID: "c", family: "claude", kind: "claude-token",
                                          env: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-x"], expiresAt: nil)
        #expect(refresher.track(claude, push: Machine().push) == nil)
        #expect(refresher.trackedCount == 0 && clock.sleeperCount == 0)
    }

    @Test func aFailedReadOrPushIsTriedAgainAMinuteLater() async throws {
        let clock = ManualClock(), acpmux = Acpmux(clock: clock), machine = Machine()
        let refresher = make(clock, acpmux)
        refresher.track(try started(acpmux), push: machine.push)
        try await clock.waitForSleeper()
        acpmux.fails = true
        clock.advance(by: .seconds(3_000))
        try await clock.waitForSleeper()
        #expect(clock.sleeperDeadlines == [ManualClock.Instant(offset: .seconds(3_060))])
        acpmux.fails = false
        machine.answer = .failed
        clock.advance(by: .seconds(60))
        try await clock.waitForSleeper()
        #expect(machine.pushes.count == 1)
        #expect(clock.sleeperDeadlines == [ManualClock.Instant(offset: .seconds(3_120))], "the push failed: again in a minute")
        machine.answer = .delivered
        clock.advance(by: .seconds(60))
        try await clock.waitForSleeper()
        #expect(machine.pushes.count == 2)
        #expect(clock.sleeperDeadlines.first.map { $0.offset > .seconds(3_120 + 600) } == true, "on the new token's schedule")
    }

    @Test func aChatThatIsGoneIsNoLongerRefreshed() async throws {
        let clock = ManualClock(), acpmux = Acpmux(clock: clock), machine = Machine()
        machine.answer = .gone
        // The wall clock moves to the refresh time; the refresh pass runs here, not on its timer.
        let wall = Wall()
        let refresher = CloudAgentCredentialRefresher(clock: clock, now: { Self.base.addingTimeInterval(wall.offset) },
                                                      read: { id in try acpmux.read(id) })
        refresher.track(try started(acpmux), push: machine.push)
        wall.offset = 3_000
        acpmux.wallOffset = 3_000
        await refresher.refresh("conn-1")
        #expect(machine.pushes.count == 1)
        #expect(refresher.trackedCount == 0, "the push said the chat is gone: no more refreshes")
    }

    @Test func anUntrackedAgentStopsItsTimer() async throws {
        let clock = ManualClock(), acpmux = Acpmux(clock: clock)
        let refresher = make(clock, acpmux)
        let id = try #require(refresher.track(try started(acpmux), push: Machine().push))
        try await clock.waitForSleeper()
        refresher.untrack(id)
        #expect(refresher.trackedCount == 0)
    }

    @Test func aChatStartsOnTheConnectionTheCloudStartChoseReadAtItsStart() async throws {
        var asked: [String] = []
        let credentials = CloudAgentCredentials { id in
            asked.append(id)
            return Data(#"{"family":"claude","kind":"claude-token","env":{"CLAUDE_CODE_OAUTH_TOKEN":"sk-ant-oat01-abc"},"expires_at":null}"#.utf8)
        }
        #expect(try await credentials.launchCredential(chat: "tab-1", machine: "m1") == nil, "no choice: the machine's own route")
        credentials.use(connection: "route-claude", chat: "tab-1", machine: "m1")
        let launch = try #require(try await credentials.launchCredential(chat: "tab-1", machine: "m1"))
        #expect(asked == ["route-claude"])
        #expect(launch.env == ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-abc"] && launch.family == "claude" && !launch.refreshes)
        #expect(!String(describing: launch).contains("sk-ant") && !String(reflecting: launch).contains("sk-ant"))
        var dumped = ""
        dump(launch, to: &dumped)
        #expect(!dumped.contains("sk-ant"), "the mirror names the variable only")
        // Spent once the chat started on it.
        credentials.started(chat: "tab-1", machine: "m1", on: launch) { _ in .delivered }
        #expect(credentials.connection(chat: "tab-1", machine: "m1") == nil)
    }

    @Test func aChosenConnectionThatCannotBeReadRefusesTheStart() async {
        let credentials = CloudAgentCredentials { _ in Data(#"{"error":"nope"}"#.utf8) }
        credentials.use(connection: "gone", chat: "tab", machine: "m")
        await #expect(throws: CloudAgentCredentials.Failure.unavailable(connection: "gone")) {
            try await credentials.launchCredential(chat: "tab", machine: "m")
        }
    }

    /// A chat no Cloud start chose for (`cmux chat --on vm`'s `cloud start-session`, a new chat in a
    /// machine's workspace) launches on the connection Cloud first use picks for its harness: the
    /// Claude Code login, which never serves Cloud, is skipped for the token; a harness nothing serves,
    /// or a pick that cannot be read, starts on the machine's own route instead of refusing.
    @Test func aChatNoStartChoseForLaunchesOnCloudFirstUsesPick() async throws {
        var asked: [String] = []
        var unreadable = false
        let credentials = CloudAgentCredentials { id in
            asked.append(id)
            if unreadable { return Data(#"{"error":"nope"}"#.utf8) }
            return Data(#"{"family":"claude","kind":"claude-token","env":{"CLAUDE_CODE_OAUTH_TOKEN":"sk-ant-oat01-abc"},"expires_at":null}"#.utf8)
        }
        #expect(try await credentials.launchCredential(chat: "cli-tab", machine: "m1", harness: "claude") == nil, "no rule set: the machine's own route")
        credentials.setup = CloudSetup(read: {
            CloudSetup.Snapshot(personal: [CloudSetup.Connection(id: "claude-login", families: ["claude"], servesCloud: false),
                                           CloudSetup.Connection(id: "claude-token", families: ["claude"])], organization: nil)
        })
        let launch = try #require(try await credentials.launchCredential(chat: "cli-tab", machine: "m1", harness: "claude", model: "opus"))
        #expect(asked == ["claude-token"] && launch.env.keys.sorted() == ["CLAUDE_CODE_OAUTH_TOKEN"])
        #expect(try await credentials.launchCredential(chat: "cli-tab", machine: "m1", harness: "codex") == nil && asked.count == 1, "nothing serves codex: no read")
        unreadable = true
        #expect(try await credentials.launchCredential(chat: "cli-tab", machine: "m1", harness: "claude") == nil, "an unreadable pick is the machine's own route")
        // A Cloud start's own choice still wins over the rule.
        unreadable = false
        credentials.use(connection: "route-claude", chat: "cli-tab", machine: "m1")
        _ = try await credentials.launchCredential(chat: "cli-tab", machine: "m1", harness: "claude")
        #expect(asked.last == "route-claude")
    }

    /// Move to Cloud (and Move to Another Machine): the moved chat's agent gets the credential a new chat on that machine
    /// starts on, pushed to its tab there; a ChatGPT plan token is then kept fresh like a started chat's.
    @Test func aMovedChatGetsTheCredentialANewChatThereStartsOn() async throws {
        var asked: [String] = []
        let credentials = CloudAgentCredentials { id in
            asked.append(id)
            return Data(#"{"family":"codex","kind":"chatgpt-plan","env":{"CMUX_CHATGPT_ACCESS_TOKEN":"tok-1"},"expires_at":4000000000}"#.utf8)
        }
        credentials.setup = CloudSetup(read: {
            CloudSetup.Snapshot(personal: [CloudSetup.Connection(id: "chatgpt", families: ["codex"])], organization: nil)
        })
        let machine = Machine()
        #expect(await credentials.moved(chat: "moved-tab", machine: "m1", harness: "codex", push: machine.push))
        #expect(asked == ["chatgpt"])
        #expect(machine.pushes == [["CMUX_CHATGPT_ACCESS_TOKEN": "tok-1"]], "the credential reached the moved chat's tab")
        #expect(credentials.refresher.trackedCount == 1, "a ChatGPT plan token is kept fresh on that machine")
    }

    /// A move whose credential did not reach the machine says so; a daemon that takes no credential, or nothing that
    /// serves the chat's agent, leaves the machine's own route without a push or a failure, as a start there does.
    @Test func aMovedChatsCredentialThatDoesNotReachTheMachineFails() async {
        let credentials = CloudAgentCredentials { _ in
            Data(#"{"family":"claude","kind":"claude-token","env":{"CLAUDE_CODE_OAUTH_TOKEN":"sk-ant-oat01-abc"},"expires_at":null}"#.utf8)
        }
        let machine = Machine()
        #expect(await credentials.moved(chat: "t", machine: "m1", harness: "claude", push: machine.push), "no rule: nothing to send")
        #expect(machine.pushes.isEmpty)
        credentials.setup = CloudSetup(read: {
            CloudSetup.Snapshot(personal: [CloudSetup.Connection(id: "claude-token", families: ["claude"])], organization: nil)
        })
        machine.answer = .failed
        #expect(await credentials.moved(chat: "t", machine: "m1", harness: "claude", push: machine.push) == false)
        machine.answer = .gone
        #expect(await credentials.moved(chat: "t", machine: "m1", harness: "claude", push: machine.push), "a daemon that takes none")
        #expect(machine.pushes.count == 2 && credentials.refresher.trackedCount == 0)
        #expect(await credentials.moved(chat: "t", machine: "m1", harness: "codex", push: machine.push) && machine.pushes.count == 2,
                "nothing serves codex: no push")
    }

    /// The Cloud start hands its choice to the launch: a `.connection` names its id, every other choice
    /// none, and a tab that got another key than the start planned keeps the choice.
    @Test func theStartsChoiceReachesTheLaunchUnderTheTabsKey() {
        #expect(CloudSetup.Choice.connection(id: "route-claude", family: "claude").connectionID == "route-claude")
        #expect(CloudSetup.Choice.organization(family: "claude").connectionID == nil && CloudSetup.Choice.fallback.connectionID == nil)
        let credentials = CloudAgentCredentials()
        credentials.use(connection: "route-claude", chat: "planned", machine: "m1")
        credentials.move(chat: "planned", to: "tab-9", machine: "m1")
        #expect(credentials.connection(chat: "tab-9", machine: "m1") == "route-claude" && credentials.connection(chat: "planned", machine: "m1") == nil)
        credentials.move(chat: "none", to: "tab-9", machine: "m1")
        #expect(credentials.connection(chat: "tab-9", machine: "m1") == "route-claude", "no choice to move leaves the tab's own")
        #expect(CloudSetup.Action.setUpClaude.settingsRow == "claude" && CloudSetup.Action.addKey.settingsRow == "apiKey" && CloudSetup.Action.openSettings.settingsRow == nil)
    }
}

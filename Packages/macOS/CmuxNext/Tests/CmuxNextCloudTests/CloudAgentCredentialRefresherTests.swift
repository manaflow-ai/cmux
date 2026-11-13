@testable import CmuxNextCloud
import CmuxNextDaemon
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
        private var sent: [AgentSessionAttachClient.LaunchCredential] = []
        var answer: CloudAgentCredentialRefresher.PushOutcome = .delivered
        var pushes: [[String: String]] { lock.withLock { got } }
        var credentials: [AgentSessionAttachClient.LaunchCredential] { lock.withLock { sent } }

        var push: CloudAgentCredentialRefresher.Push {
            { [self] credential in lock.withLock { got.append(credential.env); sent.append(credential); return answer } }
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

    @Test func thePushCarriesTheConnectionAndTheNewExpiry() async throws {
        let clock = ManualClock(), acpmux = Acpmux(clock: clock), machine = Machine()
        let refresher = make(clock, acpmux)
        refresher.track(try started(acpmux), push: machine.push)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(3_000))
        try await clock.waitForSleeper()
        let sent = try #require(machine.credentials.first)
        #expect(sent.connection == "conn-1")
        #expect(sent.expiresAt == Date(timeIntervalSince1970: acpmux.expiry))
        #expect(!String(describing: sent).contains("token-"), "the description names the variable only")
    }

    // MARK: - A chat's start and its reattach

    private static func codexReply(expiresIn: TimeInterval = 3_600) -> Data {
        let expires = Int(Date().timeIntervalSince1970 + expiresIn)
        return Data(#"{"family":"codex","kind":"chatgpt-plan","env":{"CMUX_CHATGPT_ACCESS_TOKEN":"eyJ.fresh.sig"},"expires_at":\#(expires)}"#.utf8)
    }

    @Test func aStartReadsTheConnectionItsCloudStartChose() async throws {
        var asked: [String] = []
        let credentials = CloudAgentCredentials { id in
            asked.append(id)
            return Data(#"{"family":"claude","kind":"claude-token","env":{"CLAUDE_CODE_OAUTH_TOKEN":"sk-ant-oat01-abc"},"expires_at":null}"#.utf8)
        }
        let refusal = CloudAgentCredentials.Failure.unavailable(connection: "refused")
        let mismatch = CloudAgentCredentials.Failure.unavailable(connection: "mismatch")
        #expect(try await credentials.launchCredential(connection: nil, family: "claude", refusal: refusal, mismatch: mismatch) == nil, "no choice: the machine's own route")
        #expect(asked.isEmpty)
        let launch = try #require(try await credentials.launchCredential(connection: "route-claude", family: "claude", refusal: refusal, mismatch: mismatch))
        #expect(asked == ["route-claude"])
        #expect(launch.env == ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-abc"] && launch.family == "claude" && !launch.refreshes)
        #expect(launch.launch.connection == "route-claude" && launch.launch.expiresAt == nil)
        #expect(!String(describing: launch).contains("sk-ant") && !String(reflecting: launch).contains("sk-ant"))
        #expect(!String(describing: launch.launch).contains("sk-ant") && !String(reflecting: launch.launch).contains("sk-ant"))
        var dumped = ""
        dump(launch, to: &dumped)
        dump(launch.launch, to: &dumped)
        #expect(!dumped.contains("sk-ant"), "the mirror names the variable only")
        await #expect(throws: mismatch, "switched to another agent after the choice: refused, never the machine's own route") {
            try await credentials.launchCredential(connection: "route-claude", family: "codex", refusal: refusal, mismatch: mismatch)
        }
    }

    @Test func aChosenConnectionThatCannotBeReadRefusesTheStart() async {
        let credentials = CloudAgentCredentials { _ in Data(#"{"error":"nope"}"#.utf8) }
        let refusal = CloudAgentCredentials.Failure.unavailable(connection: "refused")
        await #expect(throws: refusal) {
            try await credentials.launchCredential(connection: "gone", family: "codex", refusal: refusal, mismatch: refusal)
        }
        let noAcpmux = CloudAgentCredentials()
        await #expect(throws: refusal) {
            try await noAcpmux.launchCredential(connection: "gone", family: nil, refusal: refusal, mismatch: refusal)
        }
    }

    @Test func aChatGPTStartIsKeptFreshAndItsMachineGoingStopsIt() async throws {
        let credentials = CloudAgentCredentials { _ in Self.codexReply() }
        let launch = try #require(try await credentials.launchCredential(connection: "chatgpt-1", family: "codex", refusal: CloudAgentCredentials.Failure.unavailable(connection: "x"),
                                                                             mismatch: CloudAgentCredentials.Failure.unavailable(connection: "y")))
        let id = try #require(credentials.started(chat: "tab-1", machine: "m1", on: launch) { _ in .delivered })
        #expect(credentials.refresher.isTracked(id) && credentials.trackedChats == 1)
        credentials.machineRemoved("m2")
        #expect(credentials.trackedChats == 1, "another machine")
        credentials.machineRemoved("m1")
        #expect(!credentials.refresher.isTracked(id) && credentials.trackedChats == 0)
    }

    @Test func aReattachedChatOnTheOwnersTokenIsTrackedFromTheMachinesExpiry() async throws {
        var reads = 0
        let credentials = CloudAgentCredentials { _ in reads += 1; return Self.codexReply() }
        let machine = Machine()
        let held = Date().addingTimeInterval(1_200)
        let status = AgentSessionAttachClient.CredentialStatus(connection: "chatgpt-1", expiresAt: held, chatgpt: true, lost: false)
        credentials.reattach(chat: "tab-1", machine: "m1", status: { status }, push: machine.push)
        // A second attach while the first reads (a reconnect): one status read, one track.
        credentials.reattach(chat: "tab-1", machine: "m1", status: { status }, push: machine.push)
        await credentials.reattachesSettled()
        #expect(reads == 1 && credentials.trackedChats == 1)
        #expect(machine.pushes.isEmpty, "the machine has its token: nothing sent until it nears expiry")
        credentials.reattach(chat: "tab-1", machine: "m1", status: { status }, push: machine.push)
        await credentials.reattachesSettled()
        #expect(reads == 1, "already kept: not read again")
    }

    @Test func aCredentialTheMachineLostIsSentAgainAtOnce() async throws {
        let credentials = CloudAgentCredentials { _ in Self.codexReply() }
        let machine = Machine()
        let status = AgentSessionAttachClient.CredentialStatus(connection: "chatgpt-1", expiresAt: Date().addingTimeInterval(1_200), chatgpt: true, lost: true)
        credentials.reattach(chat: "tab-1", machine: "m1", status: { status }, push: machine.push)
        await credentials.reattachesSettled()
        #expect(machine.pushes == [["CMUX_CHATGPT_ACCESS_TOKEN": "eyJ.fresh.sig"]])
        #expect(machine.credentials.first?.connection == "chatgpt-1")
        #expect(credentials.trackedChats == 1)
    }

    @Test func aClaudeTokenTheMachineLostIsSentAgainOnEachConnectionThatFindsItLost() async throws {
        var reads = 0
        let credentials = CloudAgentCredentials { _ in
            reads += 1
            return Data(#"{"family":"claude","kind":"claude-token","env":{"CLAUDE_CODE_OAUTH_TOKEN":"sk-ant-oat01-abc"},"expires_at":null}"#.utf8)
        }
        let machine = Machine()
        let lost = AgentSessionAttachClient.CredentialStatus(connection: "claude-token", expiresAt: nil, chatgpt: false, lost: true)
        let held = AgentSessionAttachClient.CredentialStatus(connection: "claude-token", expiresAt: nil, chatgpt: false, lost: false)
        credentials.reattach(chat: "tab-1", machine: "m1", status: { lost }, push: machine.push)
        await credentials.reattachesSettled()
        #expect(machine.pushes == [["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-abc"]], "a token that never expires is sent again too")
        #expect(credentials.trackedChats == 0, "nothing to keep fresh")
        // The next connection finds it held: nothing read, nothing sent.
        credentials.reattach(chat: "tab-1", machine: "m1", status: { held }, push: machine.push)
        await credentials.reattachesSettled()
        #expect(reads == 1 && machine.pushes.count == 1)
        // The machine's acpmux restarted again while this Mac stayed connected: the page's new
        // connection finds it lost and it is sent again.
        credentials.reattach(chat: "tab-1", machine: "m1", status: { lost }, push: machine.push)
        await credentials.reattachesSettled()
        #expect(machine.pushes.count == 2)
    }

    @Test func aKeptChatGPTChatWhoseMachineLostItIsSentAgainAndKeptOnce() async throws {
        let credentials = CloudAgentCredentials { _ in Self.codexReply() }
        let machine = Machine()
        let launch = try #require(try await credentials.launchCredential(connection: "chatgpt-1", family: "codex", refusal: CloudAgentCredentials.Failure.unavailable(connection: "x"),
                                                                         mismatch: CloudAgentCredentials.Failure.unavailable(connection: "y")))
        credentials.started(chat: "tab-1", machine: "m1", on: launch, push: machine.push)
        let lost = AgentSessionAttachClient.CredentialStatus(connection: "chatgpt-1", expiresAt: launch.expiresAt, chatgpt: true, lost: true)
        credentials.reattach(chat: "tab-1", machine: "m1", status: { lost }, push: machine.push)
        await credentials.reattachesSettled()
        #expect(machine.pushes.count == 1, "kept fresh already, but the machine lost it: sent at once")
        #expect(credentials.trackedChats == 1, "one refresh for the chat, not two")
    }

    @Test func aChatOnTheMachinesOwnRouteOrAnUnreadableStatusIsLeftAsItIs() async throws {
        var reads = 0
        let credentials = CloudAgentCredentials { _ in reads += 1; return Self.codexReply() }
        let machine = Machine()
        credentials.reattach(chat: "tab-1", machine: "m1", status: { nil }, push: machine.push)
        credentials.reattach(chat: "tab-2", machine: "m1", status: { throw CloudAgentCredentials.Failure.unavailable(connection: "x") }, push: machine.push)
        await credentials.reattachesSettled()
        #expect(reads == 0 && machine.pushes.isEmpty && credentials.trackedChats == 0)
        // A connection this Mac no longer has: nothing sent, nothing tracked.
        let signedOut = CloudAgentCredentials { _ in Data(#"{"error":"signed_out"}"#.utf8) }
        let lost = AgentSessionAttachClient.CredentialStatus(connection: "chatgpt-1", expiresAt: nil, chatgpt: true, lost: true)
        signedOut.reattach(chat: "tab-3", machine: "m1", status: { lost }, push: machine.push)
        await signedOut.reattachesSettled()
        #expect(machine.pushes.isEmpty && signedOut.trackedChats == 0)
    }

    /// The Cloud start's choice names a connection only for `.connection`, and the card's actions map to their Settings rows.
    @Test func theChoiceNamesItsConnection() {
        #expect(CloudSetup.Choice.connection(id: "route-claude", family: "claude").connectionID == "route-claude")
        #expect(CloudSetup.Choice.organization(family: "claude").connectionID == nil && CloudSetup.Choice.fallback.connectionID == nil)
        #expect(CloudSetup.Action.setUpClaude.settingsRow == "claude" && CloudSetup.Action.addKey.settingsRow == "apiKey" && CloudSetup.Action.openSettings.settingsRow == nil)
    }
}

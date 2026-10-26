import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// `cmux cloud start-session` (Lawrence: "start new VMs from acp chat"): its arguments are checked
/// before anything starts, an agent's run asks in its own chat, and every failure names the machine
/// and the agent and gives the command to run next.
@MainActor @Suite(.serialized)
struct CloudStartSessionTests {
    static func fixture() -> (services: AppServices, session: CloudMachineSession) {
        let services = MachineIconTests.services()
        AppActions.bind(services)
        return (services, MachineIconTests.cloudMachine(services, id: "vm-start-\(UUID().uuidString.prefix(8))"))
    }

    static let account: [String?] = ["user-1", "team-1"]

    static let asked = CloudStartSession.Request(machineID: "vm-x", name: nil, agent: "claude", cwd: nil).asked(machine: "dev")

    static func invocation(target: String? = nil, _ arguments: [String: ActionValue], origin: ActionOrigin = .cli, agent: String? = nil) -> ActionInvocation {
        var invocation = ActionInvocation(target: target.map { ActionTargetRef(kind: .machine, id: $0) }, arguments: arguments, origin: origin)
        invocation.callerAgentSession = agent
        return invocation
    }

    static func refusal(_ services: AppServices, _ invocation: ActionInvocation) throws -> String? {
        let invoke = try #require(services.registry.action(for: CloudStartSession.action)?.invoke, "cloudStartSession is not bound")
        return services.registry.capturingRefusal { invoke(invocation) }
    }

    @Test func itIsACLIVerbAndAnMCPToolThatWaitsForThePerson() throws {
        let descriptor = try #require(Self.fixture().services.registry.descriptor(for: CloudStartSession.action))
        let text = try #require(descriptor.description, "no description for cmux action describe and MCP")
        #expect(text.contains("--target machine:<id>") && text.contains("session_id") && text.count <= 600)
        #expect(descriptor.cliName == "cloud start-session")
        #expect(descriptor.cli)
        #expect(descriptor.surfacePlan.mcp?.isOffered == true)
        #expect(descriptor.waitsForPerson, "an agent's run waits for the person's Start on its card")
        #expect(descriptor.targets == [.machine])
    }

    // MARK: Arguments

    @Test func theRequestTakesTheTargetNameAgentAndFolder() throws {
        let request = try CloudStartSession.request(Self.invocation(target: "vm-a", ["agent": .string(" codex "), "name": .string(" dev "), "cwd": .string("/home/cmux/work/app")]))
        #expect(request == CloudStartSession.Request(machineID: "vm-a", name: "dev", agent: "codex", cwd: "/home/cmux/work/app"))
        let bare = try CloudStartSession.request(Self.invocation(["agent": .string("claude"), "name": .string(""), "cwd": .string("")]))
        #expect(bare == CloudStartSession.Request(machineID: nil, name: nil, agent: "claude", cwd: nil))
    }

    @Test(arguments: ["", "Claude Code", "-rf", "claude;rm", String(repeating: "a", count: 65)])
    func aBadAgentIsRefused(agent: String) {
        #expect(throws: ActionFailure(message: CloudStartSessionStrings.agentInvalid)) {
            try CloudStartSession.request(Self.invocation(["agent": .string(agent)]))
        }
    }

    @Test(arguments: ["work", "~/work", "/a\u{7}b"])
    func aFolderThatIsNoAbsolutePathIsRefused(cwd: String) {
        #expect(throws: ActionFailure(message: CloudStartSessionStrings.cwdInvalid)) {
            try CloudStartSession.request(Self.invocation(["agent": .string("claude"), "cwd": .string(cwd)]))
        }
    }

    // MARK: Refusals before anything starts

    @Test func aScriptRunWithoutAMachineSaysHowToNameOne() throws {
        let services = Self.fixture().services
        let refusal = try Self.refusal(services, Self.invocation(["agent": .string("claude")]))
        #expect(refusal == CloudStartSessionStrings.needsMachine(agent: "claude"))
        #expect(refusal?.contains("cmux cloud start-session --target machine:<id> --agent claude") == true)
    }

    @Test func anAgentOutsideAChatIsRefusedBeforeAnyCard() throws {
        let f = Self.fixture()
        let refusal = try Self.refusal(f.services, Self.invocation(target: f.session.machineID, ["agent": .string("claude")], agent: "session-not-here"))
        let byID = CloudStartSession.Request(machineID: f.session.machineID, name: nil, agent: "claude", cwd: nil)
        #expect(refusal == CloudStartSessionStrings.notInChat(byID.asked(machine: f.session.machine.title)))
        #expect(refusal?.contains("`cmux cloud start-session --target machine:\(f.session.machineID) --agent claude`") == true)
        let mcp = try Self.refusal(f.services, Self.invocation(["agent": .string("claude"), "name": .string("my dev")], origin: .mcp))
        let byName = CloudStartSession.Request(machineID: nil, name: "my dev", agent: "claude", cwd: nil)
        #expect(mcp == CloudStartSessionStrings.notInChat(byName.asked(machine: "my dev")))
        #expect(mcp?.contains("`cmux cloud start-session --name 'my dev' --agent claude`") == true)
    }

    /// A nested run inside an MCP run is the agent's too: it asks, never starts.
    @Test func aNestedRunOfAnMCPRunIsAnAgentsRun() {
        let inner = ActionInvocation(target: ActionTargetRef(kind: .machine, id: "vm-a"), arguments: ["agent": .string("claude")])
        #expect(!CloudStartSession.isAgent(inner))
        ActionRunScope.$current.withValue(ActionRunScope(origin: .mcp, allowsViewChange: false)) {
            #expect(CloudStartSession.isAgent(inner))
        }
    }

    @Test func theCommandToRunAgainKeepsEveryArgument() {
        #expect(CloudStartSession.Request(machineID: "vm-a", name: nil, agent: "codex", cwd: "/home/cmux/my work").command
                == "cmux cloud start-session --target machine:vm-a --agent codex --cwd '/home/cmux/my work'")
        #expect(CloudStartSession.Request(machineID: nil, name: "dev", agent: "claude", cwd: nil).command == "cmux cloud start-session --name dev --agent claude")
    }

    /// An agent in a chat on a Cloud machine (one this command started) asks in that chat too.
    @Test func anAgentInAChatOnACloudMachineIsFound() throws {
        let f = Self.fixture()
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 7), kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "registry:vm-x", session: "remote-session-1", harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat])])
        f.session.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let found = try #require(CloudStartSession.chat("remote-session-1", services: f.services), "the machine's chat was not found")
        #expect(found.agentSession?.session == "remote-session-1")
        #expect(CloudStartSession.chat("no-such-session", services: f.services) == nil)
    }

    @Test func aRunStillStartingAnswersPendingWithWhatToRunNext() async throws {
        let request = CloudStartSession.Request(machineID: "vm-a", name: nil, agent: "claude", cwd: nil)
        let pending = CloudStartSession.pending(request, Self.fixture().services)
        #expect(pending["pending"] == .bool(true))
        #expect(pending["machine_id"] == .string("vm-a"))
        #expect(pending["text"] == .string(CloudStartSessionStrings.stillStarting(request.asked(machine: "vm-a"))))
        guard case .string(let text)? = pending["text"] else { Issue.record("pending has no text"); return }
        #expect(text.contains("`cmux cloud start-session --target machine:vm-a --agent claude`"))
        // Through the race: the caller's wait ends before the run.
        let runs = CloudStartSessionRuns()
        runs.sleep = { _ in }
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let answered = try await runs.answer(CloudStartSessionRuns.Key(request, caller: nil, account: Self.account), within: CloudStartSession.answerWithin, pending: pending) {
            for await _ in gate { break }
            return ["session_id": .string("s")]
        }
        #expect(answered["pending"] == .bool(true) && answered["session_id"] == nil)
    }

    @Test func aCardThatCannotShowStartsNothingAndLeavesNoAskOpen() async {
        let services = Self.fixture().services
        let asks = CloudStartSessionAsks()
        for _ in 0..<2 {
            await #expect(throws: ActionFailure(message: CloudStartSessionStrings.noPage(Self.asked))) {
                try await asks.ask(tab: "tab-without-page", text: "ask", asked: Self.asked, services: services)
            }
        }
    }

    // MARK: Failures name the machine and the agent, and give the next command

    @Test func aRefusedStartSaysTheMachineIsUpAndWhatToRun() {
        let refused = AgentRemoteStartRefusal(code: "agent_session.acpmux_unavailable", machine: "devbox-3")
        let message = CloudStartSession.startFailure(refused, name: "devbox-3", id: "vm-devbox3", agent: "codex")
        #expect(message.hasPrefix("Machine `devbox-3` started but its agent didn't ("))
        #expect(message.contains("cmux cloud start-session --target machine:vm-devbox3 --agent codex"))
        #expect(!message.contains(".)"), "the reason's own period sits inside the parentheses: \(message)")
    }

    @Test(arguments: [AgentRemoteStartRefusal.folderNeededCode, "agent_session.home_unconfirmed", "agent_session.above_home"])
    func aStartWithNoFolderSaysToPassOne(code: String) {
        let message = CloudStartSession.startFailure(AgentRemoteStartRefusal(code: code, machine: "devbox-3"), name: "devbox-3", id: "vm-devbox3", agent: "claude")
        #expect(message == CloudStartSessionStrings.needsFolder("devbox-3", id: "vm-devbox3", agent: "claude"))
        #expect(message.contains("--cwd"))
    }

    @Test func everyHintNamesAVerbTheCLIOffers() {
        let services = Self.fixture().services
        let messages = [
            CloudStartSessionStrings.needsMachine(agent: "claude"), CloudStartSessionStrings.noSuchMachine(id: "vm-x", agent: "claude"),
            CloudStartSessionStrings.agentInvalid, CloudStartSessionStrings.cwdInvalid, CloudStartSessionStrings.stillStarting(Self.asked),
            CloudStartSessionStrings.listUnread(Self.asked),
            CloudStartSessionStrings.createFailed("dev", quoted: "dev", agent: "claude", reason: "x"), CloudStartSessionStrings.notConnected("dev", id: "vm-x", agent: "claude"),
            CloudStartSessionStrings.agentFailed("dev", id: "vm-x", agent: "claude", reason: "x"), CloudStartSessionStrings.needsFolder("dev", id: "vm-x", agent: "claude"),
            CloudStartSessionStrings.notInChat(Self.asked), CloudStartSessionStrings.noPage(Self.asked), CloudStartSessionStrings.askOpen(Self.asked),
            CloudStartSessionStrings.declined(Self.asked), CloudStartSessionStrings.expired(Self.asked),
        ]
        let offered = Set(services.registry.descriptors.filter(\.cli).map(\.cliName))
        for message in messages {
            let verbs = message.components(separatedBy: "`cmux ").dropFirst().map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
            #expect(!verbs.isEmpty, "no command in: \(message)")
            for verb in verbs { #expect(offered.contains(verb.trimmingCharacters(in: CharacterSet(charactersIn: "`,.;:"))), "\(verb) is not a CLI verb") }
        }
    }

    // MARK: A machine that can't be created

    /// With no machine list read (no Cloud sign-in), `--name` refuses rather than make a second
    /// machine of a name that may exist, and says what to check and run.
    @Test func aNameWithAnUnreadMachineListCreatesNothingAndSaysWhatToCheck() async throws {
        let services = Self.fixture().services
        let name = "fresh-\(UUID().uuidString.prefix(6).lowercased())"
        let invoke = try #require(services.registry.action(for: CloudStartSession.action)?.invoke)
        let run = services.registry.capturingRun { invoke(Self.invocation(["agent": .string("claude"), "name": .string(name)])) }
        let task = try #require(run.results.first, "start-session tracked no result")
        guard case .failure(let failure) = await task.value else {
            Issue.record("a --name run with no machine list went through")
            return
        }
        #expect(failure.message.hasPrefix("Couldn't read your Cloud machines, so claude didn't start: a machine named \(name) may already exist."), "\(failure.message)")
        #expect(failure.message.contains("`cmux cloud list-machines`"))
        #expect(failure.message.contains("`cmux cloud start-session --name \(name) --agent claude`"))
        #expect(!services.machines.cloud.contains { $0.machine.title == name })
    }

    /// Two asks for one new name share one creation; another account's ask makes its own.
    @Test func twoRunsForOneNewNameCreateOnce() async throws {
        let f = Self.fixture()
        let runs = CloudStartSessionRuns()
        let (joins, join) = AsyncStream<String>.makeStream()
        runs.joinedCreation = { join.yield($0) }
        // One gate per creation, each finished at the end: a second creation (the bug) never shares one.
        var gates: [AsyncStream<Void>.Continuation] = []
        defer { for gate in gates { gate.finish() }; join.finish() }
        let (entered, enter) = AsyncStream<Int>.makeStream()
        defer { enter.finish() }
        let creates = Box(0)
        func create() -> @MainActor () async throws -> CloudMachineSession {
            let (gate, open) = AsyncStream<Void>.makeStream()
            gates.append(open)
            return {
                creates.value += 1
                enter.yield(creates.value)
                for await _ in gate { break }
                return f.session
            }
        }
        let first = Task { @MainActor in try await runs.creating("dev", account: Self.account, create()) }
        for await _ in entered { break }
        let second = Task { @MainActor in try await runs.creating("dev", account: Self.account, create()) }
        for await name in joins { #expect(name == "dev"); break }
        gates[0].yield()
        let one = try await first.value
        let two = try await second.value
        #expect(creates.value == 1)
        #expect(one === f.session && two === f.session)
        // Another team's ask for the same name is its own creation.
        let other = Task { @MainActor in try await runs.creating("dev", account: ["user-1", "team-2"], create()) }
        for await count in entered { #expect(count == 2); break }
        gates[2].yield()
        _ = try await other.value
        #expect(creates.value == 2)
    }

    /// Another account's same ask never takes a kept run's end, and a sign-out forgets them all.
    @Test func runsArePerAccountAndASignOutForgetsThem() async throws {
        let runs = CloudStartSessionRuns()
        let request = CloudStartSession.Request(machineID: nil, name: "dev", agent: "claude", cwd: nil)
        let mine = CloudStartSessionRuns.Key(request, caller: nil, account: Self.account)
        let theirs = CloudStartSessionRuns.Key(request, caller: nil, account: ["user-2", nil])
        #expect(mine != theirs)
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        runs.sleep = { _ in }
        // Mine answers pending, then ends with nobody waiting: kept for my next ask.
        _ = try await runs.answer(mine, within: .seconds(1), pending: Self.pending) {
            for await _ in gate { break }
            return ["session_id": .string("mine")]
        }
        open.yield()
        await runs.settled(mine)
        #expect(runs.keptCount == 1)
        runs.sleep = Self.waits
        let started = Box(0)
        let fields = try await runs.answer(theirs, within: .seconds(190), pending: Self.pending) {
            started.value += 1
            return ["session_id": .string("theirs")]
        }
        #expect(fields["session_id"] == .string("theirs"))
        #expect(started.value == 1, "another account's ask ran its own start")
        #expect(runs.keptCount == 1, "mine is still kept for me")
        runs.forgetAll()
        #expect(runs.count == 0)
    }

    /// `--name` takes or creates only from a list the server answered just now for this account.
    @Test func onlyAFreshListOfThisAccountIsCurrent() {
        let now = ContinuousClock.now
        let account = Self.account
        #expect(CloudService.listIsCurrent(loadedAt: now - .seconds(5), loadedFor: account, account: account, now: now, within: CloudStartSession.listFresh))
        // A failed or superseded refresh leaves the last landing time: an old list is not current.
        #expect(!CloudService.listIsCurrent(loadedAt: now - .seconds(60), loadedFor: account, account: account, now: now, within: CloudStartSession.listFresh))
        // Never loaded, or dropped at a sign-out.
        #expect(!CloudService.listIsCurrent(loadedAt: nil, loadedFor: account, account: account, now: now, within: CloudStartSession.listFresh))
        // A team switch keeps the user: the previous team's list is not this team's.
        #expect(!CloudService.listIsCurrent(loadedAt: now, loadedFor: ["user-1", "team-0"], account: account, now: now, within: CloudStartSession.listFresh))
    }

    @Test func theRetryCommandKeepsTheNameOneShellWord() {
        #expect(CloudStartSession.shellQuoted("dev-1") == "dev-1")
        #expect(CloudStartSession.shellQuoted("my dev") == "'my dev'")
        #expect(CloudStartSession.shellQuoted("it's") == "'it'\\''s'")
        #expect(CloudStartSession.shellQuoted("a;rm -rf ~") == "'a;rm -rf ~'")
        let message = CloudStartSessionStrings.createFailed("my dev", quoted: CloudStartSession.shellQuoted("my dev"), agent: "claude", reason: "x")
        #expect(message.contains("`cmux cloud start-session --name 'my dev' --agent claude`"))
        #expect(message.hasPrefix("Couldn't create Cloud machine `my dev` (x)"))
    }

    // MARK: The card belongs to its ask until the run ends

    /// Cards shown in place of a chat page, the clicks a test sends them, and a signal per card shown.
    final class Cards {
        var shown: [String: [AgentPaneToolCard]] = [:]
        var answers: [String: AgentToolCards.Answer] = [:]
        let (events, event) = AsyncStream<String>.makeStream()

        func install(_ asks: CloudStartSessionAsks) {
            asks.present = { [unowned self] cards, tab, _, answer in
                shown[tab] = cards.isEmpty ? nil : cards
                answers[tab] = answer
                if !cards.isEmpty { event.yield(tab) }
                return true
            }
        }

        /// Waits until a card shows in `tab` (the ask reached its card).
        func shownIn(_ tab: String) async {
            for await shownTab in events where shownTab == tab { return }
        }

        func click(_ tab: String, _ action: String) { answers[tab]?("cloud-start-session-" + tab, action, nil) }
    }

    @Test func aSecondAskWhileTheFirstRunsNeverTakesItsCard() async throws {
        let services = Self.fixture().services
        let asks = CloudStartSessionAsks(), cards = Cards()
        cards.install(asks)
        let first = Task { try await asks.ask(tab: "chat-1", text: "first", asked: Self.asked, services: services) }
        await cards.shownIn("chat-1")
        #expect(cards.shown["chat-1"]?.first?.state == .ask)
        cards.click("chat-1", "start")
        let token = try await first.value
        // Started: the run goes on, and the chat's card is still the first ask's.
        asks.show(tab: "chat-1", token: token, .working, "starting", services: services)
        await #expect(throws: ActionFailure(message: CloudStartSessionStrings.askOpen(Self.asked))) {
            _ = try await asks.ask(tab: "chat-1", text: "second", asked: Self.asked, services: services)
        }
        #expect(cards.shown["chat-1"]?.first?.text == "starting")
        // Another ask's token changes nothing.
        asks.finish(tab: "chat-1", token: UUID(), failure: "not yours", services: services)
        #expect(cards.shown["chat-1"]?.first?.text == "starting")
        asks.finish(tab: "chat-1", token: token, failure: "Machine `dev` started but its agent didn't (x).", services: services)
        #expect(cards.shown["chat-1"]?.first?.state == .failed)
        #expect(asks.open["chat-1"] == nil, "the chat may ask again")
        cards.click("chat-1", "dismiss")
        #expect(cards.shown["chat-1"] == nil)
    }

    @Test func notNowStartsNothingAndFreesTheChat() async throws {
        let services = Self.fixture().services
        let asks = CloudStartSessionAsks(), cards = Cards()
        cards.install(asks)
        let ask = Task { try await asks.ask(tab: "chat-2", text: "ask", asked: Self.asked, services: services) }
        await cards.shownIn("chat-2")
        cards.click("chat-2", "notNow")
        await #expect(throws: ActionFailure(message: CloudStartSessionStrings.declined(Self.asked))) { _ = try await ask.value }
        #expect(cards.shown["chat-2"] == nil)
        #expect(asks.open["chat-2"] == nil)
    }

    // MARK: A run that outlasts its caller's answer

    /// What the runs' work counts and the clock they read, shared with their closures.
    @MainActor final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    static let key = CloudStartSessionRuns.Key(CloudStartSession.Request(machineID: nil, name: "dev", agent: "codex", cwd: nil), caller: "chat-9", account: Self.account)
    static let pending: CloudStartSessionRuns.Fields = ["pending": .bool(true)]
    /// A caller's wait that never ends by itself (the run's end cancels it).
    static let waits: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }

    @Test func aRunItsCallerSawEndIsNotKept() async throws {
        let runs = CloudStartSessionRuns()
        runs.sleep = Self.waits
        let started = Box(0)
        let work: @MainActor () async throws -> CloudStartSessionRuns.Fields = {
            started.value += 1
            return ["session_id": .string("s-\(started.value)")]
        }
        #expect(try await runs.answer(Self.key, within: .seconds(190), pending: Self.pending, work)["session_id"] == .string("s-1"))
        #expect(runs.count == 0)
        #expect(try await runs.answer(Self.key, within: .seconds(190), pending: Self.pending, work)["session_id"] == .string("s-2"), "a new session, not the last one")
    }

    @Test func theSameAskWhileARunGoesOnWaitsForItAndTakesItsEnd() async throws {
        let runs = CloudStartSessionRuns()
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let started = Box(0)
        let work: @MainActor () async throws -> CloudStartSessionRuns.Fields = {
            started.value += 1
            for await _ in gate { break }
            return ["session_id": .string("s-1")]
        }
        // The first caller's wait ends at once: it answers pending, and the run goes on.
        runs.sleep = { _ in }
        #expect(try await runs.answer(Self.key, within: .seconds(190), pending: Self.pending, work) == Self.pending)
        // The second caller is waiting when its own wait begins: that lets the run end.
        runs.sleep = { _ in
            open.yield(())
            try? await Task.sleep(for: .seconds(3600))
        }
        #expect(try await runs.answer(Self.key, within: .seconds(190), pending: Self.pending, work)["session_id"] == .string("s-1"))
        #expect(started.value == 1)
        #expect(runs.count == 0, "it reached a caller, so it is not kept")
    }

    @Test func aRunEveryCallerLeftIsHandedToTheNextSameAskOnce() async throws {
        let runs = CloudStartSessionRuns()
        let clock = Box(ContinuousClock.now)
        runs.now = { clock.value }
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let started = Box(0)
        let work: @MainActor () async throws -> CloudStartSessionRuns.Fields = {
            started.value += 1
            for await _ in gate { break }
            return ["session_id": .string("s-\(started.value)")]
        }
        runs.sleep = { _ in }
        #expect(try await runs.answer(Self.key, within: .seconds(190), pending: Self.pending, work) == Self.pending)
        open.yield(())
        await runs.settled(Self.key)
        #expect(runs.count == 1, "nobody saw it end")
        runs.sleep = Self.waits
        #expect(try await runs.answer(Self.key, within: .seconds(190), pending: Self.pending, work)["session_id"] == .string("s-1"))
        #expect(started.value == 1)
        #expect(runs.count == 0, "handed out once")
    }

    @Test func aKeptRunExpiresForTheSameAsk() async throws {
        let runs = CloudStartSessionRuns()
        let clock = Box(ContinuousClock.now)
        runs.now = { clock.value }
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let slow: @MainActor () async throws -> CloudStartSessionRuns.Fields = {
            for await _ in gate { break }
            return ["session_id": .string("old")]
        }
        runs.sleep = { _ in }
        _ = try await runs.answer(Self.key, within: .seconds(190), pending: Self.pending, slow)
        open.yield(())
        await runs.settled(Self.key)
        clock.value += CloudStartSessionRuns.kept + .seconds(1)
        runs.sleep = Self.waits
        let fresh = try await runs.answer(Self.key, within: .seconds(190), pending: Self.pending) { ["session_id": .string("new")] }
        #expect(fresh["session_id"] == .string("new"))
        #expect(runs.count == 0)
    }

    @Test func aFailedRunEveryCallerLeftIsHandedOutOnceToo() async throws {
        let runs = CloudStartSessionRuns()
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let failing: @MainActor () async throws -> CloudStartSessionRuns.Fields = {
            for await _ in gate { break }
            throw ActionFailure(message: "Machine `dev` started but its agent didn't (x).")
        }
        runs.sleep = { _ in }
        _ = try await runs.answer(Self.key, within: .seconds(190), pending: Self.pending, failing)
        open.yield(())
        await runs.settled(Self.key)
        runs.sleep = Self.waits
        await #expect(throws: ActionFailure(message: "Machine `dev` started but its agent didn't (x).")) {
            _ = try await runs.answer(Self.key, within: .seconds(190), pending: Self.pending, failing)
        }
        #expect(runs.count == 0)
    }

    @Test func runsThatEndTogetherKeepAtMostTheLimit() async throws {
        let runs = CloudStartSessionRuns()
        runs.sleep = { _ in }
        let total = CloudStartSessionRuns.limit + 8
        let keys = (0..<total).map { CloudStartSessionRuns.Key(CloudStartSession.Request(machineID: "vm-\($0)", name: nil, agent: "claude", cwd: nil), caller: nil, account: Self.account) }
        // One gate per run: a stream has one reader at a time.
        let gates = keys.map { _ in AsyncStream<Void>.makeStream() }
        defer { for gate in gates { gate.continuation.finish() } }
        for (key, gate) in zip(keys, gates) {
            _ = try await runs.answer(key, within: .seconds(190), pending: Self.pending) {
                for await _ in gate.stream { break }
                return ["session_id": .string("s")]
            }
        }
        // Every caller answered pending; now every run ends.
        for gate in gates { gate.continuation.yield(()) }
        for key in keys { await runs.settled(key) }
        #expect(runs.keptCount <= CloudStartSessionRuns.limit)
    }
}

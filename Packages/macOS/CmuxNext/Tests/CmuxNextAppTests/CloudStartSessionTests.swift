import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCompat
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

    /// An agent's run in a Cloud machine's chat shows its card there; a sign-out or team switch
    /// while it asks (``CloudService``'s account observer) refuses the run and clears the card.
    @Test func anAccountChangeWhileTheAgentsCardAsksRefusesAndClearsIt() async throws {
        let f = Self.fixture()
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 8), kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "registry:\(f.session.machineID)", session: "asking-session", harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat])])
        f.session.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let asks = f.services.cloud.startSessionAsks
        let (shown, show) = AsyncStream<[AgentPaneToolCard]>.makeStream()
        defer { show.finish() }
        asks.present = { cards, _, _ in
            show.yield(cards)
            return true
        }
        let invoke = try #require(f.services.registry.action(for: CloudStartSession.action)?.invoke)
        let run = f.services.registry.capturingRun {
            invoke(Self.invocation(target: f.session.machineID, ["agent": .string("claude")], origin: .mcp, agent: "asking-session"))
        }
        let task = try #require(run.results.first, "start-session tracked no result")
        let asking = try #require(await Self.cards(shown) { !$0.isEmpty }, "the agent's card never showed")
        #expect(asking.first?.state == .ask)
        // What the account observer does on a sign-out or team switch.
        f.services.cloud.startSessionRuns.forgetAll()
        f.services.cloud.startSessionAsks.endAll()
        guard case .failure(let failure) = await task.value else {
            Issue.record("the agent's run went on after its account ended")
            return
        }
        let request = CloudStartSession.Request(machineID: f.session.machineID, name: nil, agent: "claude", cwd: nil)
        #expect(failure.message == CloudStartSessionStrings.accountChanged(request.asked(machine: f.session.machine.title)))
        #expect(await Self.cards(shown) { $0.isEmpty } != nil, "the agent's card stayed")
        #expect(f.session.daemon.connection == nil, "nothing connected")
    }

    /// The first cards `shown` yields that `match` takes, or nil once the stream ends or 10 seconds
    /// pass: a run that fails before its card shows, or never clears it, fails instead of hanging.
    static func cards(_ shown: AsyncStream<[AgentPaneToolCard]>, _ match: @escaping @Sendable ([AgentPaneToolCard]) -> Bool) async -> [AgentPaneToolCard]? {
        // concurrency-allow: the test's ten-second bound on a card the run shows or clears
        await withTaskGroup(of: [AgentPaneToolCard]?.self) { group in
            group.addTask {
                for await cards in shown where match(cards) { return cards }
                return nil
            }
            group.addTask {
                // wakeup-allow: one-shot ten-second test deadline
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    /// The person closing the new chat's tab before the store answered is not an account change:
    /// the refusal says the tab closed and gives the command. A run that was cancelled stays so.
    @Test func closingTheNewTabAfterStartSaysSoAndGivesTheCommand() async throws {
        let closed = AgentTabPending(key: "provisional", surface: SurfaceID(rawValue: 9))
        // What the store's creation throws once the person closed the provisional tab.
        closed.result = Task { throw CancellationError() }
        do {
            _ = try await CloudStartSession.created(closed, name: "devbox", id: "vm-devbox", agent: "codex")
            Issue.record("a closed tab started")
        } catch let refusal as CloudStartSession.AccountChanged {
            #expect(refusal.failure.message == CloudStartSessionStrings.tabClosed("devbox", id: "vm-devbox", agent: "codex"))
            #expect(refusal.failure.message.contains("`cmux cloud start-session --target machine:vm-devbox --agent codex`"))
            #expect(refusal.failure.message != CloudStartSessionStrings.accountChanged(CloudStartSession.Request(machineID: "vm-devbox", name: nil, agent: "codex", cwd: nil).asked(machine: "devbox")))
        }
        let cancelled = Task { @MainActor () -> (any Error)? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await CloudStartSession.created(closed, name: "devbox", id: "vm-devbox", agent: "codex")
                return nil
            } catch {
                return error
            }
        }
        let error = await cancelled.value
        #expect(error is CancellationError, "a cancelled run's error: \(String(describing: error))")
    }

    /// Closing the tab while its start is going on (the store cancels that start) says the tab
    /// closed; an ended account says so; the run's own cancellation stays one.
    @Test func closingTheTabDuringTheStartSaysSo() async throws {
        let asked = CloudStartSession.Request(machineID: "vm-devbox", name: nil, agent: "codex", cwd: nil).asked(machine: "devbox")
        let closed: () async throws -> AgentTabRemoteStart.Started = { throw CancellationError() }
        func refusal(now: [String?], _ start: () async throws -> AgentTabRemoteStart.Started) async -> String? {
            do {
                _ = try await CloudStartSession.starting(name: "devbox", id: "vm-devbox", agent: "codex", account: Self.account, now: { now }, asked: asked, start)
                return nil
            } catch let refusal as CloudStartSession.AccountChanged {
                return refusal.failure.message
            } catch {
                return "\(error)"
            }
        }
        #expect(await refusal(now: Self.account, closed) == CloudStartSessionStrings.tabClosed("devbox", id: "vm-devbox", agent: "codex"))
        #expect(await refusal(now: ["user-1", "team-2"], closed) == CloudStartSessionStrings.accountChanged(asked))
        let started = try await CloudStartSession.starting(name: "devbox", id: "vm-devbox", agent: "codex", account: Self.account, now: { Self.account }, asked: asked) {
            AgentTabRemoteStart.Started(surface: 2, session: "s-2")
        }
        #expect(started == AgentTabRemoteStart.Started(surface: 2, session: "s-2"))
        let cancelled = Task { @MainActor () -> (any Error)? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await CloudStartSession.starting(name: "devbox", id: "vm-devbox", agent: "codex", account: Self.account, now: { Self.account }, asked: asked, closed)
                return nil
            } catch {
                return error
            }
        }
        let error = await cancelled.value
        #expect(error is CancellationError, "a cancelled run's start: \(String(describing: error))")
    }

    /// What a keyed start did on the machine, in order.
    nonisolated final class StartSteps: Sendable {
        let steps = Mutex([String]())
        func note(_ step: String) { steps.withLock { $0.append(step) } }
        var all: [String] { steps.withLock { $0 } }
    }

    /// A new chat's host on a machine whose first keyed try is refused as safe to restart.
    static func keyedHost(_ steps: StartSteps, servesKeyedReason: Bool) -> AgentTabRemoteHost {
        let approvals = AgentPaneRemoteApprovals(machineID: "vm-keyed-\(UUID().uuidString.prefix(8))", label: "devbox", restart: { nil }, prepare: { _ in
            steps.note("prepare")
            return true
        })
        var host = AgentTabRemoteHost(surface: 1, session: nil, machine: "devbox", endpoint: { throw CancellationError() },
                                      servesKeyedReason: servesKeyedReason, approvals: approvals)
        host.start = { _, _, key in
            steps.note(key == nil ? "start" : "start keyed")
            if key != nil { throw AgentRemoteStartRefusal(code: AgentSessionAttachError.needsKeyedStart, machine: "devbox", keyedRestartSafe: true) }
            return AgentTabRemoteStart.Started(surface: 1, session: "s-1")
        }
        return host
    }

    /// A sign-out or team switch during a keyed start stops it before the next restart or start
    /// try on that machine; a start that goes through is reported as it is.
    @Test(arguments: [false, true])
    func anAccountChangeStopsAKeyedStartBeforeItsNextStep(servesKeyedReason: Bool) async throws {
        let asked = Self.asked
        // Signed out before anything ran: nothing runs on the machine.
        let before = StartSteps()
        await #expect(throws: CloudStartSession.AccountChanged.self) {
            try await Self.keyedHost(before, servesKeyedReason: servesKeyedReason).startNow(cwd: nil, harness: "claude") { @MainActor in
                try CloudStartSession.check(Self.account, now: [nil, nil], asked)
            }
        }
        #expect(before.all.isEmpty, "\(before.all)")
        // Signed out once the first step ran: the next restart or start never runs.
        let after = StartSteps()
        await #expect(throws: CancellationError.self) {
            try await Self.keyedHost(after, servesKeyedReason: servesKeyedReason).startNow(cwd: nil, harness: "claude") {
                if !after.all.isEmpty { throw CancellationError() }
            }
        }
        #expect(after.all == [servesKeyedReason ? "start keyed" : "prepare"], "\(after.all)")
        // The same account throughout: the restart and the start run, and the start is the answer.
        let through = StartSteps()
        let started = try await Self.keyedHost(through, servesKeyedReason: servesKeyedReason).startNow(cwd: nil, harness: "claude") {}
        #expect(started == AgentTabRemoteStart.Started(surface: 1, session: "s-1"))
        #expect(through.all == (servesKeyedReason ? ["start keyed", "prepare", "start"] : ["prepare", "start"]), "\(through.all)")
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
        let answered = try await runs.answer(CloudStartSessionRuns.Key(request, caller: nil, account: Self.account), within: CloudStartSession.answerWithin, pending: pending,
                                             forgotten: CloudStartSession.forgotten(request, Self.fixture().services)) {
            for await _ in gate { break }
            return ["session_id": .string("s")]
        }
        #expect(answered["pending"] == .bool(true) && answered["session_id"] == nil)
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

    /// A run asked in one account stops before its next step once another is signed in: the
    /// refusal says so and gives the command, and nothing is created.
    @Test func aRunAskedInAnotherAccountStartsNothing() async throws {
        let services = Self.fixture().services
        let name = "team-\(UUID().uuidString.prefix(6).lowercased())"
        let request = CloudStartSession.Request(machineID: nil, name: name, agent: "claude", cwd: nil)
        let asked = ["user-1", "team-A"] as [String?]
        #expect(asked != services.cloud.account)
        do {
            _ = try await CloudStartSession(services: services).run(request, Self.invocation(["agent": .string("claude"), "name": .string(name)]),
                                                                    AppActionContext(services: services), account: asked, byPerson: false)
            Issue.record("a run asked in another account went on")
        } catch let failure as ActionFailure {
            #expect(failure.message == CloudStartSessionStrings.accountChanged(request.asked(machine: name)))
            #expect(failure.message.contains("`cmux cloud start-session --name \(name) --agent claude`"))
        }
        #expect(!services.machines.cloud.contains { $0.machine.title == name })
    }

    /// A machine in the store whose account's list isn't the one read now (after a team switch,
    /// the previous team's machines stay until that list lands) is never a target.
    @Test func aTargetOutsideTheListOfTheAccountSignedInNowStartsNothing() async throws {
        let f = Self.fixture()
        #expect(!f.services.cloud.hasLoadedCurrentMachines)
        let invoke = try #require(f.services.registry.action(for: CloudStartSession.action)?.invoke)
        let run = f.services.registry.capturingRun { invoke(Self.invocation(target: f.session.machineID, ["agent": .string("claude")])) }
        let task = try #require(run.results.first, "start-session tracked no result")
        guard case .failure(let failure) = await task.value else {
            Issue.record("a target outside this account's list went on")
            return
        }
        let request = CloudStartSession.Request(machineID: f.session.machineID, name: nil, agent: "claude", cwd: nil)
        #expect(failure.message == CloudStartSessionStrings.targetUnread(request.asked(machine: f.session.machineID)))
        #expect(failure.message.contains("`cmux cloud start-session --target machine:\(f.session.machineID) --agent claude`"))
        #expect(f.session.daemon.connection == nil, "nothing connected")
    }

    @Test func theAccountCheckRefusesAChangeAndStopsACancelledRun() async throws {
        let asked = Self.asked
        #expect(throws: Never.self) { try CloudStartSession.checked(Self.account, now: Self.account, asked) }
        #expect(throws: CloudStartSession.AccountChanged.self) { try CloudStartSession.check(Self.account, now: ["user-1", "team-2"], asked) }
        #expect(throws: ActionFailure.self) { try CloudStartSession.checked(Self.account, now: [nil, nil], asked) }
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return Result { try CloudStartSession.checked(Self.account, now: Self.account, asked) }
        }
        guard case .failure(let error) = await cancelled.value else { Issue.record("a cancelled run went on"); return }
        #expect(error is CancellationError)
    }

    /// A step that failed while the run was cancelled or its account ended says that, never that
    /// the step itself failed (a machine that didn't connect, an agent that didn't start).
    @Test func aStepFailureAfterCancellationOrAnAccountChangeSaysSo() async throws {
        let asked = Self.asked, step = CloudStartSessionStrings.notConnected("dev", id: "vm-x", agent: "claude")
        #expect(throws: ActionFailure(message: step)) { try CloudStartSession.failed(Self.account, now: Self.account, asked, step) }
        #expect(throws: ActionFailure(message: CloudStartSessionStrings.accountChanged(asked))) {
            try CloudStartSession.failed(Self.account, now: ["user-1", "team-2"], asked, step)
        }
        let cancelled = Task { @MainActor () -> (any Error)? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try CloudStartSession.failed(Self.account, now: Self.account, asked, step) } catch { return error }
        }
        let error = await cancelled.value
        #expect(error is CancellationError, "a cancelled run's step failure: \(String(describing: error))")
    }

    /// `--name` takes or creates only from a list the server answered just now for this account.
    @Test func onlyAFreshListOfThisAccountIsCurrent() {
        let now = ContinuousClock.now
        let account = Self.account
        #expect(CloudListRetry.listIsCurrent(loadedAt: now - .seconds(5), loadedFor: account, account: account, now: now, within: CloudStartSession.listFresh))
        // A failed or superseded refresh leaves the last landing time: an old list is not current.
        #expect(!CloudListRetry.listIsCurrent(loadedAt: now - .seconds(60), loadedFor: account, account: account, now: now, within: CloudStartSession.listFresh))
        // Never loaded, or dropped at a sign-out.
        #expect(!CloudListRetry.listIsCurrent(loadedAt: nil, loadedFor: account, account: account, now: now, within: CloudStartSession.listFresh))
        // A team switch keeps the user: the previous team's list is not this team's.
        #expect(!CloudListRetry.listIsCurrent(loadedAt: now, loadedFor: ["user-1", "team-0"], account: account, now: now, within: CloudStartSession.listFresh))
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
}

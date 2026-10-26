import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
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
        #expect(refusal == CloudStartSessionStrings.notInChat)
        let mcp = try Self.refusal(f.services, Self.invocation(["agent": .string("claude"), "name": .string("dev")], origin: .mcp))
        #expect(mcp == CloudStartSessionStrings.notInChat)
    }

    @Test func aCardThatCannotShowStartsNothingAndLeavesNoAskOpen() async {
        let services = Self.fixture().services
        let asks = CloudStartSessionAsks()
        for _ in 0..<2 {
            await #expect(throws: ActionFailure(message: CloudStartSessionStrings.noPage)) {
                try await asks.ask(tab: "tab-without-page", text: "ask", services: services)
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
            CloudStartSessionStrings.agentInvalid, CloudStartSessionStrings.cwdInvalid, CloudStartSessionStrings.stillStarting,
            CloudStartSessionStrings.createFailed("dev", agent: "claude", reason: "x"), CloudStartSessionStrings.notConnected("dev", id: "vm-x", agent: "claude"),
            CloudStartSessionStrings.agentFailed("dev", id: "vm-x", agent: "claude", reason: "x"), CloudStartSessionStrings.needsFolder("dev", id: "vm-x", agent: "claude"),
            CloudStartSessionStrings.notInChat, CloudStartSessionStrings.noPage, CloudStartSessionStrings.askOpen,
            CloudStartSessionStrings.declined, CloudStartSessionStrings.expired,
        ]
        let offered = Set(services.registry.descriptors.filter(\.cli).map(\.cliName))
        for message in messages {
            let verbs = message.components(separatedBy: "`cmux ").dropFirst().map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
            #expect(!verbs.isEmpty, "no command in: \(message)")
            for verb in verbs { #expect(offered.contains(verb.trimmingCharacters(in: CharacterSet(charactersIn: "`,.;:"))), "\(verb) is not a CLI verb") }
        }
    }

    // MARK: A machine that can't be created

    @Test func aMachineThatCannotBeCreatedSaysSoWithTheCommand() async throws {
        let services = Self.fixture().services
        let name = "fresh-\(UUID().uuidString.prefix(6).lowercased())"
        let invoke = try #require(services.registry.action(for: CloudStartSession.action)?.invoke)
        let run = services.registry.capturingRun { invoke(Self.invocation(["agent": .string("claude"), "name": .string(name)])) }
        let task = try #require(run.results.first, "start-session tracked no result")
        guard case .failure(let failure) = await task.value else { return Issue.record("a create with no Cloud sign-in went through") }
        #expect(failure.message.hasPrefix("Couldn't create Cloud machine `\(name)` ("), "\(failure.message)")
        #expect(failure.message.contains("`cmux cloud start-session --name \(name) --agent claude`"))
        #expect(!failure.message.contains(".)"))
    }

    // MARK: The card belongs to its ask until the run ends

    /// Yields to the main actor's other tasks until `ready` (at most 50 turns; no clock).
    static func settle(_ ready: () -> Bool) async {
        for _ in 0..<50 where !ready() { await Task.yield() }
    }

    /// Cards shown in place of a chat page, and the clicks a test sends them.
    final class Cards {
        var shown: [String: [AgentPaneToolCard]] = [:]
        var answers: [String: AgentToolCards.Answer] = [:]

        func install(_ asks: CloudStartSessionAsks) {
            asks.present = { [unowned self] cards, tab, _, answer in
                shown[tab] = cards.isEmpty ? nil : cards
                answers[tab] = answer
                return true
            }
        }

        func click(_ tab: String, _ action: String) { answers[tab]?("cloud-start-session-" + tab, action, nil) }
    }

    @Test func aSecondAskWhileTheFirstRunsNeverTakesItsCard() async throws {
        let services = Self.fixture().services
        let asks = CloudStartSessionAsks(), cards = Cards()
        cards.install(asks)
        let first = Task { try await asks.ask(tab: "chat-1", text: "first", services: services) }
        await Self.settle { cards.shown["chat-1"] != nil }
        #expect(cards.shown["chat-1"]?.first?.state == .ask)
        cards.click("chat-1", "start")
        let token = try await first.value
        // Started: the run goes on, and the chat's card is still the first ask's.
        asks.show(tab: "chat-1", token: token, .working, "starting", services: services)
        await #expect(throws: ActionFailure(message: CloudStartSessionStrings.askOpen)) {
            _ = try await asks.ask(tab: "chat-1", text: "second", services: services)
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
        let ask = Task { try await asks.ask(tab: "chat-2", text: "ask", services: services) }
        await Self.settle { cards.shown["chat-2"] != nil }
        cards.click("chat-2", "notNow")
        await #expect(throws: ActionFailure(message: CloudStartSessionStrings.declined)) { _ = try await ask.value }
        #expect(cards.shown["chat-2"] == nil)
        #expect(asks.open["chat-2"] == nil)
    }

    // MARK: A run that outlasts its caller's answer

    /// What the runs' work counts and the clock they read, shared with their closures.
    @MainActor final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    @Test func theSameAskWhileARunGoesOnJoinsIt() async throws {
        let runs = CloudStartSessionRuns()
        let key = CloudStartSessionRuns.Key(CloudStartSession.Request(machineID: "vm-a", name: nil, agent: "claude", cwd: nil), caller: nil)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let started = Box(0)
        let work: @MainActor () async throws -> CloudStartSessionRuns.Fields = {
            started.value += 1
            for await _ in gate { break }
            return ["session_id": .string("s-1")]
        }
        let first = Task { try await runs.join(key, answeredWithin: .seconds(190), work) }
        await Self.settle { started.value == 1 }
        let second = Task { try await runs.join(key, answeredWithin: .seconds(190), work) }
        await Self.settle { false } // lets the second join reach the running one
        open.yield(())
        #expect(try await first.value["session_id"] == .string("s-1"))
        #expect(try await second.value["session_id"] == .string("s-1"))
        #expect(started.value == 1)
        // Its caller saw it end: the next same ask starts a new run.
        #expect(runs.count == 0)
    }

    @Test func aRunThatOutlastedItsCallerIsHandedOutOnce() async throws {
        let runs = CloudStartSessionRuns()
        let clock = Box(ContinuousClock.now)
        runs.now = { clock.value }
        let key = CloudStartSessionRuns.Key(CloudStartSession.Request(machineID: nil, name: "dev", agent: "codex", cwd: nil), caller: "chat-9")
        let started = Box(0)
        let slow: @MainActor () async throws -> CloudStartSessionRuns.Fields = {
            started.value += 1
            clock.value += .seconds(300) // longer than the caller waits
            return ["session_id": .string("s-\(started.value)")]
        }
        #expect(try await runs.join(key, answeredWithin: .seconds(190), slow)["session_id"] == .string("s-1"))
        #expect(runs.count == 1, "kept for the caller that got pending")
        #expect(try await runs.join(key, answeredWithin: .seconds(190), slow)["session_id"] == .string("s-1"))
        #expect(started.value == 1)
        #expect(try await runs.join(key, answeredWithin: .seconds(190), slow)["session_id"] == .string("s-2"), "handed out once")
        // Kept at most ten minutes.
        clock.value += CloudStartSessionRuns.kept + .seconds(1)
        let other = CloudStartSessionRuns.Key(CloudStartSession.Request(machineID: "vm-b", name: nil, agent: "codex", cwd: nil), caller: nil)
        _ = try await runs.join(other, answeredWithin: .seconds(190)) { ["session_id": .string("b")] }
        #expect(runs.count == 0)
    }
}

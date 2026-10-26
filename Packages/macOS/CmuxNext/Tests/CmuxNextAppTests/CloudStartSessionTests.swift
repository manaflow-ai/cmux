import AppKit
import CmuxNextActions
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
            CloudStartSessionStrings.agentInvalid, CloudStartSessionStrings.notConnected("dev", id: "vm-x", agent: "claude"),
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
}

import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextHomeEngine
import CmuxNextHostedChief
import Foundation
import Testing

/// Chief computer take-over: who drives a Chief's computer. A Cloud machine's lease lives in the
/// app (`cloud computer-control`, ``ChiefComputerControlStore``); a Cloud Chief's own sandbox's lives
/// in the Worker, reached through its owner routes (``ChiefComputerControlClient``). The profile's
/// Computer tab reads both through ``AppServices/chiefComputerControlSource(agent:machine:)``.
@MainActor @Suite(.serialized)
struct ChiefComputerControlTests {
    // MARK: `cloud computer-control` through the registry

    static func services() -> AppServices {
        let services = CloudListMachinesTests.services()
        services.cloud.computerControl.now = { 1_700_000_000_000 }
        return services
    }

    static func machine() -> String { "vm-control-\(UUID().uuidString.prefix(8).lowercased())" }

    /// The run's result, or the refusal.
    static func run(_ services: AppServices, _ arguments: [String: ActionValue], origin: ActionOrigin) async -> (fields: [String: ActionResultValue]?, refusal: String?) {
        var captured: (work: [ActionWork], results: [ActionResultWork]) = ([], [])
        let refusal = services.registry.capturingRefusal {
            captured = services.registry.capturingRun {
                _ = services.registry.perform("cloud.computerControl", invocation: ActionInvocation(arguments: arguments, origin: origin))
            }
        }
        guard let task = captured.results.first, case .success(let fields) = await task.value else { return (nil, refusal) }
        return (fields, refusal)
    }

    @Test func aMachineNobodyChangedIsTheChiefs() async throws {
        let services = Self.services()
        let machine = Self.machine()
        let answer = await Self.run(services, ["machine": .string(machine), "action": .string("status")], origin: .mcp)
        let fields = try #require(answer.fields, "refused: \(answer.refusal ?? "")")
        #expect(fields["machine"] == .string(machine))
        #expect(fields["holder"] == .string("chief"))
        #expect(fields["since_ms"] == .int(0))
        #expect(fields["reason"] == nil)
    }

    /// The Chief asks the person (its tool runs as the CLI), the profile and its next `status` see
    /// the person holding it with the reason, and the Chief's own hand_back ends its ask.
    @Test func theChiefAsksThePersonAndEndsItsOwnAsk() async throws {
        let services = Self.services()
        let machine = Self.machine()
        _ = MachineIconTests.cloudMachine(services, id: machine)
        let source = try #require(services.chiefComputerControlSource(agent: nil, machine: machine))
        var changes = 0
        let token = source.observe { changes += 1 }

        let asked = await Self.run(services, ["machine": .string(machine), "action": .string("request_human"),
                                              "reason": .string("  Sign in to Gmail  ")], origin: .cli)
        let fields = try #require(asked.fields, "refused: \(asked.refusal ?? "")")
        #expect(fields["holder"] == .string("human"))
        #expect(fields["since_ms"] == .int(1_700_000_000_000))
        #expect(fields["reason"] == .string("Sign in to Gmail"))
        #expect(source.state() == HomeChiefComputerControlState(holder: .human, sinceMs: 1_700_000_000_000, reason: "Sign in to Gmail"))
        #expect(changes == 1)

        let status = await Self.run(services, ["machine": .string(machine), "action": .string("status")], origin: .mcp)
        #expect(status.fields?["holder"] == .string("human"))

        let released = await Self.run(services, ["machine": .string(machine), "action": .string("hand_back")], origin: .cli)
        #expect(released.fields?["holder"] == .string("chief"), "refused: \(released.refusal ?? "")")
        #expect(source.state()?.holder == .chief)
        #expect(changes == 2)
        withExtendedLifetime(token) {}
    }

    /// A person who took over keeps it: automation cannot hand it back to the Chief; the person can.
    @Test func onlyThePersonGivesBackWhatThePersonTookOver() async throws {
        let services = Self.services()
        let machine = Self.machine()
        let source = try #require(services.chiefComputerControlSource(agent: nil, machine: machine))
        try await source.takeOver()
        #expect(source.state()?.holder == .human)

        let refused = await Self.run(services, ["machine": .string(machine), "action": .string("hand_back")], origin: .cli)
        #expect(refused.fields == nil)
        #expect(refused.refusal?.hasPrefix("computer.user_origin_required") == true)
        #expect(source.state()?.holder == .human)

        // A later ask from the Chief changes nothing while the person drives.
        _ = await Self.run(services, ["machine": .string(machine), "action": .string("request_human"), "reason": .string("x")], origin: .cli)
        #expect(source.state()?.reason == nil)

        try await source.handBack()
        #expect(source.state()?.holder == .chief)
    }

    /// Another client (a phone, another Mac) reads but never changes the lease (default deny).
    @Test func anotherClientCannotChangeTheLease() async throws {
        let services = Self.services()
        let machine = Self.machine()
        for action in ["take_over", "request_human", "hand_back"] {
            let answer = await Self.run(services, ["machine": .string(machine), "action": .string(action)], origin: .remote)
            #expect(answer.fields == nil, "\(action) from another client was not refused")
        }
        #expect(services.cloud.computerControl.state(.machine(machine)) == .chief)
        let status = await Self.run(services, ["machine": .string(machine), "action": .string("status")], origin: .remote)
        #expect(status.fields?["holder"] == .string("chief"))
    }

    @Test func aRunWithoutAMachineOrWithAnUnknownActionIsRefused() async {
        let services = Self.services()
        let noMachine = await Self.run(services, ["action": .string("status")], origin: .cli)
        #expect(noMachine.fields == nil && noMachine.refusal != nil)
        let badID = await Self.run(services, ["machine": .string("../etc"), "action": .string("status")], origin: .cli)
        #expect(badID.fields == nil && badID.refusal != nil)
        let badAction = await Self.run(services, ["machine": .string(Self.machine()), "action": .string("grab")], origin: .cli)
        #expect(badAction.fields == nil && badAction.refusal != nil)
        // An ask about a machine this app does not list posts no banner.
        let unknown = Self.machine()
        let ask = await Self.run(services, ["machine": .string(unknown), "action": .string("request_human")], origin: .cli)
        #expect(ask.fields == nil && ask.refusal != nil)
        #expect(services.cloud.computerControl.state(.machine(unknown)) == .chief)
    }

    /// A run nested in a CLI or agent run (its scope's origin) is automation even though the nested
    /// invocation says `user`: it cannot give back what the person took over.
    @Test func aNestedRunInsideAutomationIsNotThePerson() async throws {
        let services = Self.services()
        let machine = Self.machine()
        let source = try #require(services.chiefComputerControlSource(agent: nil, machine: machine))
        try await source.takeOver()
        let refusal = ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            services.registry.capturingRefusal {
                _ = services.registry.perform("cloud.computerControl", invocation: ActionInvocation(
                    arguments: ["machine": .string(machine), "action": .string("hand_back")], origin: .user))
            }
        }
        #expect(refusal != nil)
        #expect(source.state()?.holder == .human)
    }

    /// Only the person takes over: the Chief's take_over (CLI, MCP) is refused with
    /// `computer.user_origin_required` and changes nothing.
    @Test func automationCannotTakeOver() async {
        let services = Self.services()
        let machine = Self.machine()
        for origin in [ActionOrigin.cli, .mcp, .script] {
            let answer = await Self.run(services, ["machine": .string(machine), "action": .string("take_over")], origin: origin)
            #expect(answer.fields == nil)
            #expect(answer.refusal?.hasPrefix("computer.user_origin_required") == true, "\(origin): \(answer.refusal ?? "")")
        }
        #expect(services.cloud.computerControl.state(.machine(machine)) == .chief)
    }

    /// The Worker's since_ms only grows: a status read that left before a take-over's reply never
    /// writes the older lease back.
    @Test func anOlderSandboxAnswerNeverOverwritesANewerOne() {
        let store = ChiefComputerControlStore()
        store.apply(agent: Self.agent, state: HomeChiefComputerControlState(holder: .human, sinceMs: 9), entitled: nil)
        store.apply(agent: Self.agent, state: HomeChiefComputerControlState(holder: .chief, sinceMs: 5), entitled: true)
        #expect(store.state(.agent(Self.agent)) == HomeChiefComputerControlState(holder: .human, sinceMs: 9))
        #expect(store.entitled(agent: Self.agent) == true)
        store.apply(agent: Self.agent, state: HomeChiefComputerControlState(holder: .chief, sinceMs: 12), entitled: nil)
        #expect(store.state(.agent(Self.agent))?.holder == .chief)
        store.apply(agent: Self.agent, state: HomeChiefComputerControlState(holder: .human, sinceMs: 20), entitled: nil)
        store.apply(agent: Self.agent, state: .chief, entitled: nil)
        #expect(store.state(.agent(Self.agent)) == .chief, "a reset lease (since_ms 0) lands")
    }

    @Test func aMachineSourceOpensTheDesktopAndSendsNoInput() throws {
        let services = Self.services()
        let source = try #require(services.chiefComputerControlSource(agent: nil, machine: Self.machine()))
        #expect(source.send == nil)
        #expect(source.openInteractive != nil)
        #expect(services.chiefComputerControlSource(agent: nil, machine: nil) == nil)
        #expect(services.chiefComputerControlSource(agent: "not an agent", machine: nil) == nil)
    }

    // MARK: The sandbox routes against a stub transport

    @MainActor
    final class Transport {
        var calls: [(method: String, path: String, body: [String: Any]?)] = []
        var replies: [(Int, String)] = []

        var send: HomeChiefHostedEngine.Send {
            { [self] method, path, body in
                calls.append((method, path, body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }))
                let reply = replies.isEmpty ? (500, "{}") : replies.removeFirst()
                return (reply.0, Data(reply.1.utf8))
            }
        }
    }

    static let agent = "agent_01JABCDEFGHJKMNPQRSTVWXYZ0"

    @Test func inputMapsToTheRouteJSON() {
        func body(_ input: HomeChiefComputerInput) -> NSDictionary { ChiefComputerControlClient.inputBody(input) as NSDictionary }
        #expect(body(.click(x: 10, y: 20, button: 3, count: 2)) == ["op": "click", "x": 10, "y": 20, "button": "right", "count": 2] as NSDictionary)
        #expect(body(.click(x: 1, y: 1, button: 1, count: 1))["button"] as? String == "left")
        #expect(body(.move(x: 1, y: 2)) == ["op": "move", "x": 1, "y": 2] as NSDictionary)
        #expect(body(.drag(fromX: 1, fromY: 2, toX: 3, toY: 4)) == ["op": "drag", "x": 1, "y": 2, "to_x": 3, "to_y": 4] as NSDictionary)
        #expect(body(.scroll(x: 5, y: 6, direction: "down", amount: 3)) == ["op": "scroll", "x": 5, "y": 6, "direction": "down", "amount": 3] as NSDictionary)
        #expect(body(.type("hello")) == ["op": "type", "text": "hello"] as NSDictionary)
        #expect(body(.key("ctrl+l")) == ["op": "key", "keys": "ctrl+l"] as NSDictionary)
    }

    /// The sandbox source reads the lease when the tab observes, takes over through the control
    /// route, sends input through the input route, and on `computer.not_human` reads the lease again.
    @Test func theSandboxSourceDrivesTheOwnerRoutes() async throws {
        let transport = Transport()
        let store = ChiefComputerControlStore()
        let client = ChiefComputerControlClient(send: transport.send)
        let source = HomeChiefComputerControlSource.sandbox(agent: Self.agent, store: store, client: client)
        #expect(source.state() == nil)
        #expect(source.openInteractive == nil)

        var changes = 0
        transport.replies = [(200, #"{"ok":true,"value":{"used":true,"computer":null,"control":{"holder":"chief","since_ms":5},"entitled":true}}"#)]
        let token = source.observe { changes += 1 }
        await Self.drain(store, agent: Self.agent)
        #expect(transport.calls.first?.method == "GET")
        #expect(transport.calls.first?.path == "v1/chiefs/\(Self.agent)/computer")
        #expect(source.state() == HomeChiefComputerControlState(holder: .chief, sinceMs: 5))
        #expect(store.entitled(agent: Self.agent) == true)
        #expect(changes == 1)

        transport.replies = [(200, #"{"ok":true,"value":{"control":{"holder":"human","since_ms":9}}}"#)]
        try await source.takeOver()
        #expect(transport.calls.last?.method == "POST")
        #expect(transport.calls.last?.path == "v1/chiefs/\(Self.agent)/computer/control")
        #expect(transport.calls.last?.body?["action"] as? String == "take_over")
        #expect(source.state()?.holder == .human)
        #expect(changes == 2)

        let send = try #require(source.send)
        transport.replies = [(200, #"{"ok":true,"value":{"done":true,"control":{"holder":"human","since_ms":10}}}"#)]
        try await send(.type("hi"))
        #expect(transport.calls.last?.path == "v1/chiefs/\(Self.agent)/computer/input")
        #expect(transport.calls.last?.body?["op"] as? String == "type")
        #expect(transport.calls.last?.body?["text"] as? String == "hi")
        #expect(source.state() == HomeChiefComputerControlState(holder: .human, sinceMs: 10))

        transport.replies = [(409, #"{"ok":false,"error":{"code":"computer.not_human","message":"The Chief has the computer."}}"#),
                             (200, #"{"ok":true,"value":{"used":true,"control":{"holder":"chief","since_ms":11}}}"#)]
        await #expect(throws: ChiefComputerControlClient.Failure.self) { try await send(.key("Return")) }
        await Self.drain(store, agent: Self.agent)
        #expect(source.state() == HomeChiefComputerControlState(holder: .chief, sinceMs: 11))
        withExtendedLifetime(token) {}
    }

    /// The profile's own status read every few seconds carries the lease into the store.
    @Test func theTabsStatusReadFeedsTheLease() async throws {
        let transport = Transport()
        let store = ChiefComputerControlStore()
        transport.replies = [(200, #"{"ok":true,"value":{"used":true,"control":{"holder":"human","since_ms":3,"reason":"Pick a seat"},"entitled":false}}"#)]
        let send = ChiefComputerControlClient.feeding(transport.send, into: store)
        _ = try await send("GET", "v1/chiefs/\(Self.agent)/computer", nil)
        #expect(store.state(.agent(Self.agent)) == HomeChiefComputerControlState(holder: .human, sinceMs: 3, reason: "Pick a seat"))
        #expect(store.entitled(agent: Self.agent) == false)
    }

    /// Waits for the store's status read in flight for `agent` to land.
    static func drain(_ store: ChiefComputerControlStore, agent: String) async {
        await store.refreshTask(agent: agent)?.value
    }
}

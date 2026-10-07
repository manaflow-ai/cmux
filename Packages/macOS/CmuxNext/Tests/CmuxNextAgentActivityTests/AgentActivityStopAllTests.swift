import Foundation
import Testing
@testable import CmuxNextAgentActivity

@MainActor
@Suite("Agent activity stop all")
struct AgentActivityStopAllTests {
    @Test("stop all fans out to every control source")
    func stopsEverySource() async throws {
        let first = StopSource()
        let second = StopSource()
        let coordinator = AgentActivityStopAllCoordinator(sources: [first, second])

        try await coordinator.stopAll(machine: "local")

        #expect(first.operations == [.stopAll(machine: "local")])
        #expect(second.operations == [.stopAll(machine: "local")])
    }
}

@MainActor
private final class StopSource: AgentActivitySource {
    var operations: [AgentActivityUserOp] = []
    func start(_ sink: @escaping @MainActor (AgentActivityUpdate) -> Void) {}
    func follow(session: String, _ on: Bool) {}
    func image(for frame: AgentActivityFrameRef) async -> NSImage? { nil }
    func perform(_ op: AgentActivityUserOp) async throws { operations.append(op) }
}

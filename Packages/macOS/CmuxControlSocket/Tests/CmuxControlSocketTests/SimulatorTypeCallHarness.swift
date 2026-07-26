import Foundation
@testable import CmuxControlSocket

// The harness is immutable after main-actor construction, so detached test
// calls can read its references without racing mutation.
final class SimulatorTypeCallHarness: @unchecked Sendable {
    let coordinator: ControlCommandCoordinator
    let context: FakeSimulatorControlCommandContext
    let params: [String: JSONValue]

    @MainActor
    init(
        coordinator: ControlCommandCoordinator,
        context: FakeSimulatorControlCommandContext,
        params: [String: JSONValue]
    ) {
        self.coordinator = coordinator
        self.context = context
        self.params = params
    }

    func call(timeout: TimeInterval?) -> ControlCallResult {
        coordinator.simulatorType(params, context: context, completionTimeout: timeout)
    }
}

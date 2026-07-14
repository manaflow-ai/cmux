import Foundation
@testable import CmuxControlSocket

/// Orchestration-domain fake: canned resolutions plus call recording. Every
/// other domain comes from the shared test-stub extensions.
@MainActor
final class FakeOrchestrationControlCommandContext: ControlCommandContext {
    var listResolution: ControlOrchestrationListResolution = .resolved([])
    var infoResolution: ControlOrchestrationInfoResolution = .notInstalled
    var planResolution: ControlOrchestrationPlanResolution = .notInstalled
    var runResolution: ControlOrchestrationRunResolution = .notInstalled

    private(set) var infoCall: String?
    private(set) var planCall: ControlOrchestrationRunInputs?
    private(set) var runCall: (inputs: ControlOrchestrationRunInputs, confirmTrust: Bool)?

    func controlOrchestrationList() -> ControlOrchestrationListResolution {
        listResolution
    }

    func controlOrchestrationInfo(name: String) -> ControlOrchestrationInfoResolution {
        infoCall = name
        return infoResolution
    }

    func controlOrchestrationPlan(
        inputs: ControlOrchestrationRunInputs
    ) -> ControlOrchestrationPlanResolution {
        planCall = inputs
        return planResolution
    }

    func controlOrchestrationRun(
        routing: ControlRoutingSelectors,
        inputs: ControlOrchestrationRunInputs,
        confirmTrust: Bool
    ) -> ControlOrchestrationRunResolution {
        runCall = (inputs, confirmTrust)
        return runResolution
    }
}

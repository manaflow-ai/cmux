import Foundation
@testable import CmuxControlSocket

// Benign defaults for the orchestration domain so fakes for other domains
// keep compiling without stubbing these; the orchestration tests override
// them on their own fake.
extension ControlOrchestrationContext {
    func controlOrchestrationList() -> ControlOrchestrationListResolution {
        .resolved([])
    }

    func controlOrchestrationInfo(name: String) -> ControlOrchestrationInfoResolution {
        .notInstalled
    }

    func controlOrchestrationPlan(
        inputs: ControlOrchestrationRunInputs
    ) -> ControlOrchestrationPlanResolution {
        .notInstalled
    }

    func controlOrchestrationRun(
        routing: ControlRoutingSelectors,
        inputs: ControlOrchestrationRunInputs,
        confirmTrust: Bool,
        confirmFingerprint: String?
    ) -> ControlOrchestrationRunResolution {
        .notInstalled
    }
}

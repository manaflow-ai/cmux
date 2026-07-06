import Foundation
@testable import CmuxControlSocket

// Benign defaults for the Fleet-domain seam, so a test fake that conforms to
// the full `ControlCommandContext` umbrella only has to implement the domain it
// actually exercises.

extension ControlFleetContext {
    func controlFleetList() -> [ControlFleetSnapshot] { [] }
    func controlFleetStatus(fleetID: String?) -> ControlFleetStatusResolution {
        fleetID.map { .fleetNotFound($0) } ?? .ok(ControlFleetStatusSnapshot(isRunning: false, fleets: []))
    }
    func controlFleetCreate(inputs: ControlFleetCreateInputs) -> ControlFleetCreateResolution { .engineUnavailable }
    func controlFleetStart(fleetID: String) -> ControlFleetLifecycleResolution { .engineUnavailable }
    func controlFleetStop(fleetID: String) -> ControlFleetLifecycleResolution { .engineUnavailable }
    func controlFleetTaskAdd(inputs: ControlFleetTaskAddInputs) -> ControlFleetTaskAddResolution { .engineUnavailable }
    func controlFleetTaskList(
        fleetID: String?,
        state: ControlFleetTaskStateName?
    ) -> ControlFleetTaskListResolution {
        fleetID.map { .fleetNotFound($0) } ?? .ok([])
    }
    func controlFleetTaskRetry(taskID: String) -> ControlFleetTaskActionResolution { .engineUnavailable }
    func controlFleetTaskCancel(taskID: String) -> ControlFleetTaskActionResolution { .engineUnavailable }
    func controlFleetTaskOpen(taskID: String) -> ControlFleetTaskOpenResolution { .engineUnavailable }
}

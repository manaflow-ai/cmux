import CmuxControlSocket
import Foundation

/// The Fleet-domain witnesses are PR 2 stubs for the #7361 Fleet control-socket
/// chain. PR 3 replaces these bodies with the FleetEngine bridge once the app
/// target owns live Fleet state.
extension TerminalController: ControlFleetContext {
    func controlFleetList() -> [ControlFleetSnapshot] {
        []
    }

    func controlFleetStatus(fleetID: String?) -> ControlFleetStatusResolution {
        if let fleetID {
            return .fleetNotFound(fleetID)
        }
        return .ok(ControlFleetStatusSnapshot(isRunning: false, fleets: []))
    }

    func controlFleetCreate(inputs: ControlFleetCreateInputs) -> ControlFleetCreateResolution {
        .engineUnavailable
    }

    func controlFleetStart(fleetID: String) -> ControlFleetLifecycleResolution {
        .engineUnavailable
    }

    func controlFleetStop(fleetID: String) -> ControlFleetLifecycleResolution {
        .engineUnavailable
    }

    func controlFleetTaskAdd(inputs: ControlFleetTaskAddInputs) -> ControlFleetTaskAddResolution {
        .engineUnavailable
    }

    func controlFleetTaskList(
        fleetID: String?,
        state: ControlFleetTaskStateName?
    ) -> ControlFleetTaskListResolution {
        if let fleetID {
            return .fleetNotFound(fleetID)
        }
        return .ok([])
    }

    func controlFleetTaskRetry(taskID: String) -> ControlFleetTaskActionResolution {
        .engineUnavailable
    }

    func controlFleetTaskCancel(taskID: String) -> ControlFleetTaskActionResolution {
        .engineUnavailable
    }

    func controlFleetTaskOpen(taskID: String) -> ControlFleetTaskOpenResolution {
        .engineUnavailable
    }
}

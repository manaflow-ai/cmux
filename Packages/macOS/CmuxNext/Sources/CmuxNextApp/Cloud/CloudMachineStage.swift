import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemon
import Foundation

extension CloudMachineStageInput {
    var stage: CloudMachineStage { stage(machineFailed: CloudStrings.machineFailed) } // the words are the App's
}

extension CloudMachineStage {
    /// The power actions a change on its way holds (``CloudMachine/Status/blocks(_:)``).
    static let powerActions: [(ActionID, CloudMachine.PowerAction)] = [
        ("cloudPauseMachine", .pause), ("cloudResumeMachine", .resume), ("cloudKillMachine", .kill),
    ]

    /// While a pause, resume or delete is on its way, the actions it holds are disabled in the
    /// menu with why, and every run (palette, CLI, MCP, keyboard) is refused with it. A reason
    /// another binder set first (the machine's own state) still applies after this one.
    @MainActor static func gatePowerActions(into registry: ActionRegistry, context: AppActionContext) {
        for (id, action) in powerActions {
            let earlier = registry.action(for: id)?.targetUnavailableReason
            context.setTargetReason(id) { invocation in
                let status = (try? CloudHandlers.machine(invocation, context))?.effectiveStatus
                return status.flatMap { $0.blocks(action) ? CloudStrings.machineChanging($0) : nil } ?? earlier?(invocation)
            }
        }
    }
}

/// A session holds its machine record for ``CloudMachineChanges``.
extension CloudMachineSession: CloudMachineHolder {}

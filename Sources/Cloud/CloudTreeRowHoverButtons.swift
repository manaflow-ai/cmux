import SwiftUI

/// The one hover verb of a row — interactive, so it lives in its own
/// hit-testable host beside the pass-through display content. Machines get
/// delete only (desktop lives on the Displays pool and in the context menu);
/// pools and workspace rows get their "+" creation verb.
struct CloudTreeRowHoverButtons: View {
    let kind: CloudTreeNode.Kind
    let machineName: String
    let machineActions: MachineRowActions
    let nodeActions: CloudTreeNodeActions

    var body: some View {
        switch kind {
        case .machine(let machine, _):
            MachinesChromeIconButton(
                symbolName: "trash",
                accessibilityLabel: String(localized: "machines.row.delete", defaultValue: "Delete Machine"),
                isBusy: false
            ) {
                machineActions.confirmDelete(machine.id)
            }
        case .pendingMachine(let operation):
            // A running create can be cancelled from the row; a failed create
            // can be retried or dropped.
            HStack(spacing: 4) {
                if operation.isRunning {
                    xmark(String(localized: "machines.pending.cancel", defaultValue: "Cancel Create")) {
                        machineActions.create.cancel(operation.id)
                    }
                } else {
                    MachinesChromeIconButton(
                        symbolName: "arrow.counterclockwise",
                        accessibilityLabel: String(localized: "machines.pending.retry", defaultValue: "Retry Create"),
                        isBusy: false
                    ) {
                        machineActions.create.retry(operation.id)
                    }
                    xmark(String(localized: "machines.pending.dismiss", defaultValue: "Dismiss")) {
                        machineActions.create.dismiss(operation.id)
                    }
                }
            }
        case .localMachine:
            plus(String(localized: "cloudTree.menu.newTerminalOnThisMac", defaultValue: "New Terminal on This Mac")) {
                nodeActions.newTerminal(.local, nil)
            }
        case .terminalsPool(let machine, _):
            plus(CloudTreeCreateAction.terminal(machine: machine, workspaceID: nil, name: machineName).title) {
                CloudTreeCreateAction.terminal(machine: machine, workspaceID: nil, name: machineName)
                    .perform(newMachine: {}, nodeActions: nodeActions)
            }
        case .displaysPool:
            EmptyView()
        case .workspacesGroup(let machine):
            plus(CloudTreeCreateAction.workspace(machine: machine, name: machineName).title) {
                CloudTreeCreateAction.workspace(machine: machine, name: machineName)
                    .perform(newMachine: {}, nodeActions: nodeActions)
            }
        case .workspace(let machine, let workspace, _, _, _):
            HStack(spacing: 4) {
                let action = CloudTreeCreateAction.terminal(machine: machine, workspaceID: workspace.id, name: workspace.name)
                plus(action.title) { action.perform(newMachine: {}, nodeActions: nodeActions) }
                if !machine.isLocal {
                    xmark(String(localized: "cloudTree.row.closeWorkspace", defaultValue: "Close Workspace\u{2026}")) {
                        nodeActions.closeWorkspace(machine, workspace)
                    }
                }
            }
        case .terminal(let row):
            if !row.resource.machine.isLocal {
                xmark(String(localized: "cloudTree.menu.killTerminal", defaultValue: "Kill Terminal\u{2026}")) {
                    nodeActions.closeTerminal(row.resource.id)
                }
            }
        default:
            EmptyView()
        }
    }

    /// True when this row kind renders any hover button at all.
    static func hasButtons(for kind: CloudTreeNode.Kind) -> Bool {
        switch kind {
        case .machine, .localMachine, .terminalsPool, .workspacesGroup, .workspace:
            return true
        case .pendingMachine:
            return true
        case .terminal(let row):
            return !row.resource.machine.isLocal
        default:
            return false
        }
    }

    private func plus(_ label: String, action: @escaping () -> Void) -> some View {
        MachinesChromeIconButton(symbolName: "plus", accessibilityLabel: label, isBusy: false, action: action)
    }

    private func xmark(_ label: String, action: @escaping () -> Void) -> some View {
        MachinesChromeIconButton(symbolName: "xmark", accessibilityLabel: label, isBusy: false, action: action)
    }
}

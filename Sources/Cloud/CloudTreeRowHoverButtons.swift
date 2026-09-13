import SwiftUI

struct CloudTreeRowHoverButtons: View {
    let kind: CloudTreeNode.Kind
    let machineActions: MachineRowActions
    let nodeActions: CloudTreeNodeActions

    var body: some View {
        switch kind {
        case .devicesSection(let section):
            Menu {
                DevicesSidebarControls(
                    discoveryEnabled: section.discoveryEnabled,
                    incomingAccessEnabled: section.incomingAccessEnabled,
                    discoveryManaged: section.discoveryManaged,
                    incomingAccessManaged: section.incomingAccessManaged,
                    setDiscovery: { nodeActions.setDeviceDiscovery($0) },
                    setIncomingAccess: { nodeActions.setDeviceIncomingAccess($0) }
                )
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "devices.manage", defaultValue: "Manage My Devices"))
            .accessibilityLabel(String(localized: "devices.manage", defaultValue: "Manage My Devices"))
            .accessibilityIdentifier("DevicesOptionsMenu")
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
            plus(String(localized: "cloudTree.menu.newTerminal", defaultValue: "New Terminal")) {
                nodeActions.newTerminal(.local, nil)
            }
        case .device(let row):
            // The same authenticated-connection gate as its context menu.
            if row.canCreateWorkspacesAndTerminals {
                plus(String(localized: "cloudTree.menu.newTerminal", defaultValue: "New Terminal")) {
                    nodeActions.newTerminal(row.machine, nil)
                }
            }
        case .terminalsPool(let machine, _):
            plus(String(localized: "cloudTree.menu.newTerminal", defaultValue: "New Terminal")) {
                nodeActions.newTerminal(machine, nil)
            }
        case .displaysPool:
            EmptyView()
        case .workspacesGroup(let machine):
            plus(String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace")) {
                nodeActions.newWorkspace(machine)
            }
        case .workspace(let machine, let workspace, _, _, _):
            HStack(spacing: 4) {
                plus(String(localized: "cloudTree.menu.newTerminalHere", defaultValue: "New Terminal Here")) {
                    nodeActions.newTerminal(machine, workspace.id)
                }
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
        case .machine, .localMachine, .terminalsPool, .workspacesGroup, .workspace, .devicesSection:
            return true
        case .pendingMachine:
            return true
        case .device(let row):
            return row.canCreateWorkspacesAndTerminals
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

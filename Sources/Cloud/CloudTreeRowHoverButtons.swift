import CmuxCloud
import SwiftUI

struct CloudTreeRowHoverButtons: View {
    let kind: CloudTreeNode.Kind
    /// The row's node id, for the "⋯" button's context menu. A machine still
    /// finishing its create keeps its pending id, so it can't be rebuilt from
    /// the machine alone.
    var nodeID = ""
    let machineActions: MachineRowActions
    let nodeActions: CloudTreeNodeActions

    var body: some View {
        switch kind {
        // The section headers' refresh icons sit after their counts
        // (`CloudTreeSectionRefreshHeader`), not with these buttons.
        case .devicesSection(let section):
            CloudTreeDevicesMenuButton(section: section, nodeActions: nodeActions)
        case .coderouterSection:
            MachinesChromeIconButton(
                symbolName: "questionmark.circle",
                accessibilityLabel: String(localized: "coderouter.guide.open", defaultValue: "What Is coderouter?"),
                isBusy: false
            ) {
                nodeActions.showRowGuide(nodeID)
            }
            .help(CoderouterGuideView.summary)
            .accessibilityIdentifier("CoderouterGuideButton")
        case .coderouterAccount(let account):
            xmark(String(localized: "coderouter.removeAccount", defaultValue: "Remove Account\u{2026}")) {
                nodeActions.removeCoderouterAccount(account)
            }
        case .coderouterProviderGroup(let provider, _):
            if provider.canAdd {
                plus(provider.newAccountTitle) {
                    nodeActions.addCoderouterAccount(provider)
                }
            }
        case .cloudMachinesSection(let canCreateMachine, _, _):
            if canCreateMachine {
                plus(String(localized: "machines.new", defaultValue: "New Machine")) {
                    nodeActions.newMachine()
                }
                .accessibilityIdentifier("CloudMachinesNewMachineButton")
            }
        case .machine(let machine, _):
            // Always visible: New Workspace, and the machine's full context
            // menu (Delete lives there). An expired machine's + offers the
            // upgrade, matching its menu.
            HStack(spacing: 2) {
                plus(String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace")) {
                    if machine.freeAccess == .expired {
                        machineActions.promptUpgrade()
                    } else {
                        nodeActions.newWorkspace(.cloud(machine.id))
                    }
                }
                .accessibilityIdentifier("CloudMachineNewWorkspaceButton")
                MachinesChromeIconButton(
                    symbolName: "ellipsis",
                    accessibilityLabel: String(localized: "cloudTree.machine.moreActions", defaultValue: "More Actions"),
                    isBusy: false
                ) {
                    nodeActions.showRowMenu(nodeID)
                }
                .accessibilityIdentifier("CloudMachineMoreActionsButton")
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
        case .displaysPool(let machine, _, let canCreate):
            plus(String(localized: "cloudTree.menu.newDisplay", defaultValue: "New Display")) {
                Self.performDisplayCreationIfAvailable(canCreate, unavailable: {
                    nodeActions.showHint(CloudGuestDisplaySnapshot.unavailableMessage)
                }) {
                    nodeActions.newDisplay(machine)
                }
            }
            // Keep the host hit-testable while guest discovery is pending.
            // Disabling the SwiftUI button makes AppKit hand the click to the
            // outline row, which collapses Displays instead of starting the
            // self-starting creation path.
            .opacity(canCreate ? 1 : 0.55)
            .help(canCreate ? String(localized: "cloudTree.menu.newDisplay", defaultValue: "New Display") : CloudGuestDisplaySnapshot.unavailableMessage)
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
        case .display(let resource, _, let remoteView):
            if let remoteView, remoteView.isCloudDisplayMembershipView {
                xmark(String(localized: "cloudTree.menu.removeDisplayFromWorkspace", defaultValue: "Remove from Workspace")) {
                    nodeActions.removeDisplayFromWorkspace(resource, remoteView)
                }
            }
        default:
            EmptyView()
        }
    }

    /// True when this row kind renders any hover button at all.
    static func hasButtons(for kind: CloudTreeNode.Kind) -> Bool {
        switch kind {
        case .machine, .localMachine, .terminalsPool, .displaysPool, .workspacesGroup, .workspace, .devicesSection:
            return true
        case .coderouterProviderGroup(let provider, _):
            return provider.canAdd
        case .coderouterSection, .coderouterAccount:
            return true
        case .cloudMachinesSection(let canCreateMachine, _, _):
            return canCreateMachine
        case .pendingMachine:
            return true
        case .device(let row):
            return row.canCreateWorkspacesAndTerminals
        case .terminal(let row):
            return !row.resource.machine.isLocal
        case .display(_, _, let remoteView):
            return remoteView?.isCloudDisplayMembershipView == true
        default:
            return false
        }
    }

    /// True when the row's buttons stay visible without hover. Machine rows
    /// keep + and ⋯ on screen so their actions are discoverable at rest.
    static func showsAtRest(for kind: CloudTreeNode.Kind) -> Bool {
        if case .machine = kind { return true }
        return false
    }

    /// The Displays affordance remains visible while guest discovery is pending
    /// so its unavailable state can explain itself on hover. Keep that visual
    /// affordance from dispatching a create operation until the snapshot says
    /// the machine can accept one.
    static func performDisplayCreationIfAvailable(
        _ canCreate: Bool,
        unavailable: () -> Void = {},
        action: () -> Void
    ) {
        guard canCreate else {
            unavailable()
            return
        }
        action()
    }

    private func plus(_ label: String, action: @escaping () -> Void) -> some View {
        MachinesChromeIconButton(symbolName: "plus", accessibilityLabel: label, isBusy: false, action: action)
    }

    private func xmark(_ label: String, action: @escaping () -> Void) -> some View {
        MachinesChromeIconButton(symbolName: "xmark", accessibilityLabel: label, isBusy: false, action: action)
    }
}

/// The My Devices header's "..." menu. Same size, tint and hover fill as the
/// Cloud Machines "+" (`MachinesChromeIconButton`), so both headers hover alike.
private struct CloudTreeDevicesMenuButton: View {
    let section: CloudTreeDevicesSection
    let nodeActions: CloudTreeNodeActions
    @State private var isHovered = false

    var body: some View {
        Menu {
            DevicesSidebarControls(
                discoveryEnabled: section.discoveryEnabled,
                incomingAccessEnabled: section.incomingAccessEnabled,
                discoveryManaged: section.discoveryManaged,
                incomingAccessManaged: section.incomingAccessManaged,
                unavailable: !section.available,
                setDiscovery: { nodeActions.setDeviceDiscovery($0) },
                setIncomingAccess: { nodeActions.setDeviceIncomingAccess($0) }
            )
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.buttonCornerRadius, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        // A plain button menu keeps the label's 22×20 frame as the control,
        // matching the Cloud Machines "+" in size and hit area; the
        // borderless style shrinks it to the symbol.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help(String(localized: "devices.manage", defaultValue: "Manage My Devices"))
        .accessibilityLabel(String(localized: "devices.manage", defaultValue: "Manage My Devices"))
        .accessibilityIdentifier("DevicesOptionsMenu")
    }
}

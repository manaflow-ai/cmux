import CmuxCloud
import CmuxSurfaceCatalogModel
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
        case .devicesSection(let section):
            CloudTreeDevicesMenuButton(section: section, nodeActions: nodeActions)
        case .cloudMachinesSection(let canCreateMachine, _):
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
                Self.performDisplayCreationIfAvailable(canCreate) {
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
        case .port(let resource, _, _):
            if let port = Self.shareablePort(resource) {
                CloudPortShareButton(
                    key: CloudPortShareStore.Key(machineID: resource.machine.rawValue, port: port),
                    store: CloudPortShareStore.shared
                ) {
                    nodeActions.sharePort(resource.id)
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
        case .cloudMachinesSection(let canCreateMachine, _):
            return canCreateMachine
        case .pendingMachine:
            return true
        case .device(let row):
            return row.canCreateWorkspacesAndTerminals
        case .terminal(let row):
            return !row.resource.machine.isLocal
        case .port(let resource, _, _):
            return shareablePort(resource) != nil
        default:
            return false
        }
    }

    /// A Cloud machine's forwarded port can be shared; This Mac and SSH hosts can't.
    static func shareablePort(_ resource: SurfaceResource) -> Int? {
        guard resource.machine.cloudMachineID != nil else { return nil }
        return resource.id.forwardedPort
    }

    /// True when the row's buttons stay visible without hover. Machine rows
    /// keep + and ⋯ on screen so their actions are discoverable at rest.
    static func showsAtRest(for kind: CloudTreeNode.Kind) -> Bool {
        switch kind {
        case .machine:
            return true
        case .port(let resource, _, _):
            // Sharing is the port row's main action, so it stays discoverable.
            return shareablePort(resource) != nil
        default:
            return false
        }
    }

    /// The Displays affordance remains visible while guest discovery is pending
    /// so its unavailable state can explain itself on hover. Keep that visual
    /// affordance from dispatching a create operation until the snapshot says
    /// the machine can accept one.
    static func performDisplayCreationIfAvailable(_ canCreate: Bool, action: () -> Void) {
        guard canCreate else { return }
        action()
    }

    private func plus(_ label: String, action: @escaping () -> Void) -> some View {
        MachinesChromeIconButton(symbolName: "plus", accessibilityLabel: label, isBusy: false, action: action)
    }

    private func xmark(_ label: String, action: @escaping () -> Void) -> some View {
        MachinesChromeIconButton(symbolName: "xmark", accessibilityLabel: label, isBusy: false, action: action)
    }
}

/// Share on a Cloud port row: a spinner while the link is made, a checkmark
/// once it is on the clipboard.
private struct CloudPortShareButton: View {
    let key: CloudPortShareStore.Key
    @ObservedObject var store: CloudPortShareStore
    let action: () -> Void

    var body: some View {
        let phase = store.phase(for: key)
        HStack(spacing: 2) {
            if let status = status(phase) {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            MachinesChromeIconButton(
                symbolName: symbolName(phase),
                accessibilityLabel: label(phase),
                isBusy: phase == .creating,
                action: action
            )
            .help(label(phase))
            .accessibilityIdentifier("CloudPortShareButton")
        }
        .animation(.easeOut(duration: 0.15), value: phase)
    }

    private func symbolName(_ phase: CloudPortShareStore.Phase?) -> String {
        switch phase {
        case .copied: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        case .creating, nil: return "link"
        }
    }

    /// The short inline note beside the button while sharing runs and right
    /// after the link lands on the clipboard.
    private func status(_ phase: CloudPortShareStore.Phase?) -> String? {
        switch phase {
        case .creating:
            return String(localized: "cloudTree.port.share.creating", defaultValue: "Creating link\u{2026}")
        case .copied:
            return String(localized: "cloudTree.port.share.copied", defaultValue: "Copied to clipboard")
        case .failed, nil:
            return nil
        }
    }

    private func label(_ phase: CloudPortShareStore.Phase?) -> String {
        switch phase {
        case .creating:
            return String(localized: "cloudTree.port.share.creating", defaultValue: "Creating link\u{2026}")
        case .copied(.team):
            return String(localized: "cloudTree.port.share.copiedTeam", defaultValue: "Link copied. Your team can open it after signing in.")
        case .copied(.personal):
            return String(localized: "cloudTree.port.share.copiedPersonal", defaultValue: "Link copied. Only you can open it.")
        case .copied(.public):
            return String(localized: "cloudTree.port.share.copiedPublic", defaultValue: "Link copied. Anyone with the link can open it.")
        case .failed:
            return String(localized: "cloudTree.port.share.failed", defaultValue: "Couldn't create link")
        case nil:
            return String(localized: "cloudTree.port.share", defaultValue: "Share with Team")
        }
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

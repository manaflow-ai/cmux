import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

enum WorkspaceMacSelection: Hashable {
    case automatic
    case all
    case machine(String)
}

extension WorkspaceListView {
    var macSelectionScope: WorkspaceMacSelectionScope {
        let displayPairedMacs = store?.displayPairedMacs ?? []
        return WorkspaceMacSelectionScope(
            selection: macSelection,
            workspaces: workspaces,
            displayPairedMacs: displayPairedMacs,
            foregroundMacDeviceID: store?.connectedMacDeviceID ?? store?.activeTicket?.macDeviceID,
            aliasesFor: { store?.pairedMacAliasIDs(for: $0) ?? [] }
        )
    }

    var activeFilter: MobileWorkspaceListFilter {
        macSelectionScope.activeFilter(base: filter)
    }

    var visibleMacSelection: WorkspaceMacSelection {
        macSelectionScope.visibleSelection
    }

    var liveMachineSnapshots: WorkspaceMachineSnapshots {
        let scope = macSelectionScope
        return WorkspaceMachineSnapshots(
            workspaces: workspaces,
            filterMachineIDFor: { scope.aliasIndex.representativeID(for: $0) },
            macPickerMachineIDs: scope.machineIDs,
            namesByID: macDisplayNamesByID(),
            fallbackName: fallbackMacPickerName
        )
    }

    var fallbackMacPickerName: String {
        L10n.string("mobile.workspaces.macPicker.label", defaultValue: "Computer")
    }

    func macDisplayNamesByID() -> [String: String] {
        var names: [String: String] = [:]
        for workspace in workspaces {
            guard let id = workspace.macDeviceID,
                  let name = workspace.macDisplayName,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            names[id] = name
        }
        for device in store?.deviceTreeDevices ?? [] {
            if let name = device.displayName, !name.isEmpty {
                names[device.deviceId] = name
            }
        }
        for mac in store?.pairedMacs ?? [] {
            names[mac.macDeviceID] = mac.resolvedName
        }
        for mac in store?.displayPairedMacs ?? [] {
            names[mac.macDeviceID] = mac.resolvedName
        }
        guard let buildScope = MobileIOSBuildScope.current() else { return names }
        return names.mapValues(buildScope.computerDisplayName)
    }

    var filterMenuPresentMachineIDs: [String] {
        let aliasIndex = macSelectionScope.aliasIndex
        var seen = Set<String>()
        var present: [String] = []
        for id in MobileWorkspaceListFilter.machineIDs(in: workspaces) {
            let representativeID = aliasIndex.representativeID(for: id)
            if seen.insert(representativeID).inserted {
                present.append(representativeID)
            }
        }
        return present
    }

    func filterMenuMachines(
        machineSnapshots: WorkspaceMachineSnapshots,
        visibleSelection: WorkspaceMacSelection
    ) -> [WorkspaceFilterMachine] {
        switch visibleSelection {
        case .machine:
            return []
        case .all, .automatic:
            return machineSnapshots.filterMachines
        }
    }

    var canCreateWorkspaceForMacSelection: Bool {
        macSelectionScope.canCreateWorkspace(base: canCreateWorkspace)
    }

    #if os(iOS)
    var canRenderGroupsForSelection: Bool {
        #if DEBUG
        // The store-free layout fixture has no foreground Mac, so the
        // foreground-scope gate can never pass there; render its seeded groups
        // so grouped rows and end-of-group slots are exercised in previews.
        if store == nil, UITestConfig.workspaceListLayoutPreviewEnabled {
            return true
        }
        #endif
        return macSelectionScope.canRenderGroupsForSelection
    }

    func macTitlePickerTitle(machineSnapshots: WorkspaceMachineSnapshots) -> String {
        switch visibleMacSelection {
        case .all, .automatic:
            L10n.string("mobile.workspaces.macPicker.allMacs", defaultValue: "All Computers")
        case .machine(let id):
            machineSnapshots.macPickerMachines.first { $0.id == id }?.name ?? fallbackMacPickerName
        }
    }

    var macTitlePickerSelection: Binding<WorkspaceMacSelection> {
        Binding(
            get: { currentMacTitlePickerSelection },
            set: { _ = handleMacTitlePickerSelection($0) }
        )
    }

    func macTitlePicker(machineSnapshots: WorkspaceMachineSnapshots) -> some View {
        WorkspaceMacTitlePicker(
            title: macTitlePickerTitle(machineSnapshots: machineSnapshots),
            isLoading: macTitlePickerShowsProgress,
            selection: macTitlePickerSelection,
            machines: machineSnapshots.macPickerMachines,
            showAddDevice: showAddDevice
        )
    }

    var showsDevicesButton: Bool {
        if store != nil {
            return true
        }
        #if DEBUG
        return UITestConfig.workspaceListLayoutPreviewEnabled
        #else
        return false
        #endif
    }
    #else
    var canRenderGroupsForSelection: Bool {
        true
    }
    #endif
}

#if os(iOS)
struct WorkspaceMacTitlePicker: View {
    let title: String
    let isLoading: Bool
    @Binding var selection: WorkspaceMacSelection
    let machines: [WorkspaceFilterMachine]
    let showAddDevice: (() -> Void)?
    let labelWidth: CGFloat

    init(
        title: String,
        isLoading: Bool,
        selection: Binding<WorkspaceMacSelection>,
        machines: [WorkspaceFilterMachine],
        showAddDevice: (() -> Void)?,
        labelWidth: CGFloat = 155
    ) {
        self.title = title
        self.isLoading = isLoading
        _selection = selection
        self.machines = machines
        self.showAddDevice = showAddDevice
        self.labelWidth = labelWidth
    }

    var body: some View {
        Menu {
            Picker(
                L10n.string("mobile.workspaces.macPicker.title", defaultValue: "Choose Computer"),
                selection: $selection
            ) {
                Text(L10n.string("mobile.workspaces.macPicker.allMacs", defaultValue: "All Computers"))
                    .tag(WorkspaceMacSelection.all)
                ForEach(machines) { machine in
                    Text(machine.name)
                        .tag(WorkspaceMacSelection.machine(machine.id))
                }
            }
            .labelsVisibility(.visible)
            if let showAddDevice {
                Divider()
                Button(action: showAddDevice) {
                    Label(
                        L10n.string("mobile.computers.add", defaultValue: "Add Computer"),
                        systemImage: "plus"
                    )
                }
                .accessibilityIdentifier("MobileWorkspaceMacPickerAdd")
            }
        } label: {
            WorkspaceMacTitlePickerLabel(
                title: title,
                isLoading: isLoading,
                width: labelWidth
            )
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .accessibilityIdentifier("MobileWorkspaceMacPicker")
    }
}

private struct WorkspaceMacTitlePickerLabel: View {
    let title: String
    let isLoading: Bool
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(title)
                .font(.headline.weight(.bold))
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsTightening(true)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
            ZStack {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .opacity(isLoading ? 0 : 1)
                ProgressView()
                    .controlSize(.mini)
                    .tint(.primary)
                    .opacity(isLoading ? 1 : 0)
            }
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .frame(width: width, alignment: .center)
        .clipped()
        .contentShape(Rectangle())
    }
}
#endif

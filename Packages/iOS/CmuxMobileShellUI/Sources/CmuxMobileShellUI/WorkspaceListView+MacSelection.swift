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

    var macPickerMachines: [WorkspaceFilterMachine] {
        let scope = macSelectionScope
        let names = macDisplayNamesByID()
        return scope.machineIDs
            .map { WorkspaceFilterMachine(id: $0, name: names[$0] ?? fallbackMacPickerName) }
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.id < rhs.id
            }
    }

    var fallbackMacPickerName: String {
        L10n.string("mobile.workspaces.macPicker.label", defaultValue: "Mac")
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
        return names
    }

    var canCreateWorkspaceForMacSelection: Bool {
        macSelectionScope.canCreateWorkspace(base: canCreateWorkspace)
    }

    #if os(iOS)
    var canRenderGroupsForSelection: Bool {
        macSelectionScope.canRenderGroupsForSelection
    }

    var macTitlePickerTitle: String {
        switch visibleMacSelection {
        case .all, .automatic:
            L10n.string("mobile.workspaces.macPicker.allMacs", defaultValue: "All Macs")
        case .machine(let id):
            macPickerMachines.first { $0.id == id }?.name ?? fallbackMacPickerName
        }
    }

    var macTitlePickerSelection: Binding<WorkspaceMacSelection> {
        Binding(
            get: { visibleMacSelection },
            set: { handleMacTitlePickerSelection($0) }
        )
    }

    func handleMacTitlePickerSelection(_ selection: WorkspaceMacSelection) {
        let startsMachineSwitch: Bool
        if case .machine = selection, switchMac != nil {
            startsMachineSwitch = true
        } else {
            startsMachineSwitch = false
        }
        cancelMacTitlePickerSwitch(restorePreviousOnCancel: !startsMachineSwitch)
        let generation = macTitlePickerSwitchGeneration
        guard startsMachineSwitch else {
            macSelection = selection
            return
        }
        macTitlePickerSwitchTask = Task { @MainActor in
            defer {
                if macTitlePickerSwitchGeneration == generation {
                    macTitlePickerSwitchTask = nil
                }
            }
            await applyMacTitlePickerSelection(selection, switchGeneration: generation)
        }
    }

    func cancelMacTitlePickerSwitch(restorePreviousOnCancel: Bool = true) {
        let hadPendingSwitch = macTitlePickerSwitchTask != nil
        macTitlePickerSwitchTask?.cancel()
        macTitlePickerSwitchTask = nil
        macTitlePickerSwitchGeneration &+= 1
        if hadPendingSwitch {
            cancelMacSwitch?(restorePreviousOnCancel)
        }
    }

    @MainActor
    func applyMacTitlePickerSelection(
        _ selection: WorkspaceMacSelection,
        switchGeneration: UInt64? = nil
    ) async {
        func isCurrentSwitchRequest() -> Bool {
            guard !Task.isCancelled else { return false }
            guard let switchGeneration else { return true }
            return macTitlePickerSwitchGeneration == switchGeneration
        }

        switch selection {
        case .all, .automatic:
            guard isCurrentSwitchRequest() else { return }
            macSelection = selection
        case .machine(let id):
            guard isCurrentSwitchRequest() else { return }
            guard let switchMac else {
                macSelection = selection
                return
            }
            guard await switchMac(id), isCurrentSwitchRequest() else { return }
            macSelection = .machine(id)
        }
    }

    var macTitlePicker: some View {
        Menu {
            Picker(
                L10n.string("mobile.workspaces.macPicker.title", defaultValue: "Choose Mac"),
                selection: macTitlePickerSelection
            ) {
                Text(L10n.string("mobile.workspaces.macPicker.allMacs", defaultValue: "All Macs"))
                    .tag(WorkspaceMacSelection.all)
                ForEach(macPickerMachines) { machine in
                    Text(machine.name)
                        .tag(WorkspaceMacSelection.machine(machine.id))
                }
            }
            .labelsVisibility(.visible)
            if let showAddDevice {
                Divider()
                Button {
                    showAddDevice()
                } label: {
                    Label(
                        L10n.string("mobile.computers.add", defaultValue: "Add Computer"),
                        systemImage: "plus"
                    )
                }
                .accessibilityIdentifier("MobileWorkspaceMacPickerAdd")
            }
        } label: {
            WorkspaceMacTitlePickerLabel(title: macTitlePickerTitle)
        }
        .buttonStyle(.plain)
        .tint(.white)
        .accessibilityIdentifier("MobileWorkspaceMacPicker")
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
private struct WorkspaceMacTitlePickerLabel: View {
    private static let titleWidth: CGFloat = 155

    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(title)
                .font(.headline.weight(.bold))
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsTightening(true)
                .minimumScaleFactor(0.9)
                .layoutPriority(1)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.bold))
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(width: Self.titleWidth, alignment: .center)
        .clipped()
        .contentShape(Rectangle())
    }
}
#endif

import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

enum WorkspaceMacSelection: Hashable {
    case automatic
    case all
    case machine(String)
}

extension WorkspaceListView {
    var activeFilter: MobileWorkspaceListFilter {
        let aliasIndex = macPickerAliasIndex
        var active = filter
        switch visibleMacSelection(aliasIndex: aliasIndex) {
        case .automatic:
            break
        case .all:
            active.machines.removeAll()
        case .machine(let id):
            active.machines = aliasIndex.filterMachineIDs(for: id)
        }
        return active
    }

    var visibleMacSelection: WorkspaceMacSelection {
        visibleMacSelection(aliasIndex: macPickerAliasIndex)
    }

    private func visibleMacSelection(aliasIndex: WorkspaceMacPickerAliasIndex) -> WorkspaceMacSelection {
        let machineIDs = Set(macPickerMachines(aliasIndex: aliasIndex).map(\.id))
        switch macSelection {
        case .automatic:
            return .all
        case .machine(let id):
            let representativeID = aliasIndex.representativeID(for: id)
            return machineIDs.contains(representativeID) ? .machine(representativeID) : .all
        case .all:
            return .all
        }
    }

    var macPickerMachines: [WorkspaceFilterMachine] {
        macPickerMachines(aliasIndex: macPickerAliasIndex)
    }

    private func macPickerMachines(aliasIndex: WorkspaceMacPickerAliasIndex) -> [WorkspaceFilterMachine] {
        let names = macDisplayNamesByID()
        var ids = Set<String>()
        for id in MobileWorkspaceListFilter.machineIDs(in: workspaces) {
            ids.insert(aliasIndex.representativeID(for: id))
        }
        if let store {
            for mac in store.displayPairedMacs {
                ids.insert(mac.macDeviceID)
            }
            if let connectedID = store.connectedMacDeviceID {
                ids.insert(aliasIndex.representativeID(for: connectedID))
            }
        }
        return ids
            .map { WorkspaceFilterMachine(id: $0, name: names[$0] ?? fallbackMacPickerName) }
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.id < rhs.id
            }
    }

    private var macPickerAliasIndex: WorkspaceMacPickerAliasIndex {
        guard let store else { return .empty }
        return WorkspaceMacPickerAliasIndex(
            displayPairedMacs: store.displayPairedMacs,
            aliasesFor: { store.pairedMacAliasIDs(for: $0) }
        )
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
        guard canCreateWorkspace else { return false }
        let aliasIndex = macPickerAliasIndex
        switch visibleMacSelection(aliasIndex: aliasIndex) {
        case .machine(let id):
            guard let connectedID = store?.connectedMacDeviceID else { return false }
            return aliasIndex.filterMachineIDs(for: id).contains(connectedID)
        case .all, .automatic:
            return true
        }
    }

    #if os(iOS)
    var canRenderGroupsForSelection: Bool {
        selectedMacCanUseForegroundGroups
    }

    private var selectedMacCanUseForegroundGroups: Bool {
        let aliasIndex = macPickerAliasIndex
        switch visibleMacSelection(aliasIndex: aliasIndex) {
        case .machine(let id):
            guard let connectedID = store?.connectedMacDeviceID else { return false }
            return aliasIndex.filterMachineIDs(for: id).contains(connectedID)
        case .all, .automatic:
            return visibleRowsAreOnlyForegroundMac(aliasIndex: aliasIndex)
        }
    }

    private func visibleRowsAreOnlyForegroundMac(aliasIndex: WorkspaceMacPickerAliasIndex) -> Bool {
        guard !workspaces.isEmpty else { return false }
        guard let connectedID = store?.connectedMacDeviceID else { return false }
        let foregroundIDs = aliasIndex.filterMachineIDs(for: connectedID)
        return workspaces.allSatisfy { workspace in
            guard let macDeviceID = workspace.macDeviceID else { return false }
            return foregroundIDs.contains(macDeviceID)
        }
    }

    var macTitlePickerTitle: String {
        switch visibleMacSelection {
        case .all, .automatic:
            L10n.string("mobile.workspaces.macPicker.allMacs", defaultValue: "All Macs")
        case .machine(let id):
            macPickerMachines.first { $0.id == id }?.name ?? fallbackMacPickerName
        }
    }

    var macTitlePicker: some View {
        Menu {
            Picker(
                L10n.string("mobile.workspaces.macPicker.title", defaultValue: "Choose Mac"),
                selection: $macSelection
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

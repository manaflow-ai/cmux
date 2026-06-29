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
        filter(forMacSelection: visibleMacSelection)
    }

    /// The base filter narrowed to a Mac selection, the same machine mapping the
    /// flat/grouped lists consume via `activeFilter`. Shared so per-row picker
    /// counts and the visible list agree on what a selection shows.
    func filter(forMacSelection selection: WorkspaceMacSelection) -> MobileWorkspaceListFilter {
        var active = filter
        switch selection {
        case .automatic:
            break
        case .all:
            active.machines.removeAll()
        case .machine(let id):
            active.machines = Set([id])
        }
        return active
    }

    /// Number of workspaces a Mac picker row would show if selected, so the
    /// count printed next to the row matches the list the user lands on.
    func macSelectionCount(_ selection: WorkspaceMacSelection) -> Int {
        filter(forMacSelection: selection).matchCount(in: workspaces)
    }

    var visibleMacSelection: WorkspaceMacSelection {
        let machineIDs = Set(macPickerMachines.map(\.id))
        switch macSelection {
        case .automatic:
            return .all
        case .machine(let id):
            return machineIDs.contains(id) ? .machine(id) : .all
        case .all:
            return .all
        }
    }

    var macPickerMachines: [WorkspaceFilterMachine] {
        let names = macDisplayNamesByID()
        var ids = Set(MobileWorkspaceListFilter.machineIDs(in: workspaces))
        if let connectedID = store?.connectedMacDeviceID {
            ids.insert(connectedID)
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
        return names
    }

    #if os(iOS)
    var canRenderGroupsForSelection: Bool {
        selectedMacCanUseForegroundGroups
    }

    private var selectedMacCanUseForegroundGroups: Bool {
        switch visibleMacSelection {
        case .machine(let id):
            return store?.connectedMacDeviceID == id
        case .all, .automatic:
            return visibleRowsAreOnlyForegroundMac
        }
    }

    private var visibleRowsAreOnlyForegroundMac: Bool {
        guard !workspaces.isEmpty else { return false }
        guard let connectedID = store?.connectedMacDeviceID else { return false }
        return workspaces.allSatisfy { $0.macDeviceID == connectedID }
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
                    .badge(Text(macSelectionCount(.all), format: .number))
                    .tag(WorkspaceMacSelection.all)
                ForEach(macPickerMachines) { machine in
                    Text(machine.name)
                        .badge(Text(macSelectionCount(.machine(machine.id)), format: .number))
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

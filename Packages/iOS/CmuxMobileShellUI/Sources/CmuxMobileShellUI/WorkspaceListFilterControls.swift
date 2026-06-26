import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The one filter control shared by every surface that lists workspaces (the
/// flat workspace list and the device tree): a toolbar menu with two orthogonal,
/// composable dimensions — read state (All / Unread) and machine (multi-select)
/// — so you can express e.g. "unread on Mac X and Mac Y". The machine section
/// only appears when more than one machine is present, so single-Mac users see
/// exactly the old All / Unread control.
struct WorkspaceListFilterMenu: View {
    @Binding var filter: MobileWorkspaceListFilter
    /// Machines available to filter by. When fewer than two, the machine section
    /// is hidden (nothing to disambiguate).
    var machines: [WorkspaceFilterMachine] = []

    private var showsMachineSection: Bool { machines.count > 1 }

    var body: some View {
        Menu {
            Picker(
                L10n.string("mobile.workspaces.filter.readState", defaultValue: "Show"),
                selection: $filter.readState
            ) {
                ForEach(MobileWorkspaceReadStateFilter.allCases, id: \.self) { state in
                    Text(state.displayName).tag(state)
                }
            }

            if showsMachineSection {
                Section(L10n.string("mobile.workspaces.filter.machines", defaultValue: "Machines")) {
                    Button {
                        filter.machines.removeAll()
                    } label: {
                        Label(
                            L10n.string("mobile.workspaces.filter.allMachines", defaultValue: "All Machines"),
                            systemImage: filter.machines.isEmpty ? "checkmark" : ""
                        )
                    }
                    ForEach(machines) { machine in
                        Button {
                            filter.toggleMachine(machine.id)
                        } label: {
                            Label(
                                machine.name,
                                systemImage: filter.machines.contains(machine.id) ? "checkmark" : ""
                            )
                        }
                        .accessibilityIdentifier("MobileWorkspaceFilterMachine-\(machine.id)")
                    }
                }
            }
        } label: {
            // Filled icon while a narrowing filter is active, mirroring Mail.
            Image(systemName: filter.isActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(L10n.string("mobile.workspaces.filter", defaultValue: "Filter"))
        .accessibilityIdentifier("MobileWorkspaceFilterMenu")
    }
}

extension MobileWorkspaceReadStateFilter {
    /// The localized menu title for this read-state option.
    var displayName: String {
        switch self {
        case .all:
            return L10n.string("mobile.workspaces.filter.all", defaultValue: "All Workspaces")
        case .unread:
            return L10n.string("mobile.workspaces.filter.unread", defaultValue: "Unread")
        }
    }
}

extension MobileWorkspaceListFilter {
    /// The localized copy for "this filter hid every workspace". `nil` for the
    /// identity filter, which can never hide anything. Reflects whichever
    /// dimension(s) are active.
    var emptyStateText: String? {
        guard isActive else { return nil }
        let machineScoped = !machines.isEmpty
        switch (readState, machineScoped) {
        case (.unread, true):
            return L10n.string(
                "mobile.workspaces.filter.empty.unreadOnMachines",
                defaultValue: "No unread workspaces on the selected machines"
            )
        case (.unread, false):
            return L10n.string(
                "mobile.workspaces.filter.empty.unread",
                defaultValue: "No unread workspaces"
            )
        case (.all, true):
            return L10n.string(
                "mobile.workspaces.filter.empty.machines",
                defaultValue: "No workspaces on the selected machines"
            )
        case (.all, false):
            return nil
        }
    }
}

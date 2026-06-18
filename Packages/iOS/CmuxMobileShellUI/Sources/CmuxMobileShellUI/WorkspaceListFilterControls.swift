import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The one filter control shared by every surface that lists workspaces (the
/// flat workspace list and the device tree): a toolbar menu picking a
/// ``MobileWorkspaceListFilter`` case. New filter cases added to the model show
/// up here automatically via `CaseIterable`; do not build a second per-surface
/// filter menu.
struct WorkspaceListFilterMenu: View {
    @Binding var filter: MobileWorkspaceListFilter

    var body: some View {
        Menu {
            Picker(
                L10n.string("mobile.workspaces.filter", defaultValue: "Filter"),
                selection: $filter
            ) {
                ForEach(MobileWorkspaceListFilter.allCases, id: \.self) { item in
                    Text(item.displayName).tag(item)
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

extension MobileWorkspaceListFilter {
    /// The localized menu title for this filter case.
    var displayName: String {
        switch self {
        case .all:
            return L10n.string("mobile.workspaces.filter.all", defaultValue: "All Workspaces")
        case .unread:
            return L10n.string("mobile.workspaces.filter.unread", defaultValue: "Unread")
        }
    }

    /// The localized copy for "this filter hid every workspace". `nil` for the
    /// identity filter, which can never hide anything.
    var emptyStateText: String? {
        switch self {
        case .all:
            return nil
        case .unread:
            return L10n.string(
                "mobile.workspaces.filter.empty.unread",
                defaultValue: "No unread workspaces"
            )
        }
    }
}

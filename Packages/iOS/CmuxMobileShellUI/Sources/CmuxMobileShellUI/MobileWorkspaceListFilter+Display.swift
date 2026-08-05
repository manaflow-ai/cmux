#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport

extension MobileWorkspaceListFilter {
    var emptyStateText: String? {
        guard isActive else { return nil }
        switch (readState, !machines.isEmpty) {
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
#endif

#if DEBUG && os(iOS)
import CmuxMobileShellModel

struct NotificationWorkspaceRoute: Identifiable, Hashable {
    let id: MobileWorkspacePreview.ID
}
#endif

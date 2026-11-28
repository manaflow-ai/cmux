#if os(iOS) && DEBUG
import CmuxMobileSupport

enum PushTabNavigationPreviewTargetState: Equatable {
    case home
    case connected
    case missingTab
    case missingWorkspace

    var targetLabel: String {
        switch self {
        case .home:
            return L10n.string("mobile.push.preview.home", defaultValue: "Home")
        case .connected:
            return L10n.string("mobile.push.preview.notes", defaultValue: "Notes")
        case .missingTab:
            return L10n.string(
                "mobile.push.preview.notesRemoved",
                defaultValue: "Notes tab removed"
            )
        case .missingWorkspace:
            return L10n.string(
                "mobile.push.preview.docsRemoved",
                defaultValue: "Docs workspace removed"
            )
        }
    }
}
#endif

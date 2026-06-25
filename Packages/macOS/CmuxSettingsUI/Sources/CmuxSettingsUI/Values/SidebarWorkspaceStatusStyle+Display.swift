import CmuxSettings
import Foundation

/// UI-facing labels for ``SidebarWorkspaceStatusStyle``.
extension SidebarWorkspaceStatusStyle {
    var displayName: String {
        switch self {
        case .sentence:
            return String(localized: "sidebarWorkspaceStatusStyle.sentence.name", defaultValue: "Sentence")
        case .dot:
            return String(localized: "sidebarWorkspaceStatusStyle.dot.name", defaultValue: "Dot")
        }
    }

    var rowDescription: String {
        switch self {
        case .sentence:
            return String(localized: "sidebarWorkspaceStatusStyle.sentence.description", defaultValue: "Agent status appears as a subtitle under each workspace title.")
        case .dot:
            return String(localized: "sidebarWorkspaceStatusStyle.dot.description", defaultValue: "Agent status appears as a colored dot so workspace rows stay one line.")
        }
    }
}

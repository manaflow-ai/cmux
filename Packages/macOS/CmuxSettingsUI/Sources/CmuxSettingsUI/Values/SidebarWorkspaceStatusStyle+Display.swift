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
            return String(localized: "sidebarWorkspaceStatusStyle.sentence.description", defaultValue: "Show agent status as subtitle text under each workspace title.")
        case .dot:
            return String(localized: "sidebarWorkspaceStatusStyle.dot.description", defaultValue: "Show agent status as a colored dot beside the title. Provider subtitles stay visible.")
        }
    }
}

import CmuxNextDaemon
import CmuxNextDesign

/// The place an appearance value is set on (plans/cmux-next/appearance-scopes-DESIGN.md).
@MainActor
enum AppearanceTarget {
    /// A space (room): every window showing it.
    case window(ProfileID)
    /// A workspace, by its app id.
    case workspace(String)
    /// A pane.
    case pane(PaneController)
    /// The tab a pane shows.
    case tab(PaneController, TabModel)

    var level: AppearanceLevel {
        switch self {
        case .window: .window
        case .workspace: .workspace
        case .pane: .pane
        case .tab: .tab
        }
    }
}

extension ShortcutAction {
    /// Logical grouping used for sectioning the shortcuts pane.
    public enum Group: String, CaseIterable, Sendable, Hashable {
        /// Application-wide actions.
        case app
        /// Workspace lifecycle and notification actions.
        case workspace
        /// Workspace and surface navigation actions.
        case navigation
        /// Pane layout and focus actions.
        case panes
        /// Browser, viewer, and find actions.
        case browser

        /// The English section title used by shortcut catalog consumers.
        public var title: String {
            switch self {
            case .app: return "App"
            case .workspace: return "Workspace"
            case .navigation: return "Navigation"
            case .panes: return "Panes"
            case .browser: return "Browser & Find"
            }
        }
    }
}

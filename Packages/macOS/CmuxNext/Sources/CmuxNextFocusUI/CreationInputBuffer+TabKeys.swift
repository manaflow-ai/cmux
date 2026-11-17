public import CmuxNextActions

extension CreationInputBuffer {
    /// What a held key's action does to the focused pane's tabs: it makes one and shows it (a New Tab key), or it closes
    /// the shown one (the Close Tab key).
    public enum TabKey: Sendable {
        case makes, closes

        /// The actions that make one tab in the focused pane and show it: the New Tab key in each place, New Terminal
        /// Tab, New Browser Tab.
        private static let makers: Set<ActionID> = ["newTab.default", "newTab.afterCurrent", "newTab.atStart", "newTab.atEnd", "newTab.toRight", "newSurface", "openBrowser"]

        /// What `action` (the action of a key's binding; nil: no binding) does to the tabs; nil: neither.
        public init?(action: ActionID?) {
            guard let action else { return nil }
            if action == "closeTab" { self = .closes } else if Self.makers.contains(action) { self = .makes } else { return nil }
        }
    }
}

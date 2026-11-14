import Foundation

extension Notification.Name {
    /// Asks the search field of a ``ProjectPanel``'s active tab to take keyboard
    /// focus. The notification's object is the panel's `id`.
    static let projectPanelSearchFocus = Notification.Name("projectPanelSearchFocus")
}

extension ProjectPanel {
    /// Whether the active tab shows a search field that Cmd+F can focus.
    ///
    /// The Files and Build Settings tabs filter through a search field, but
    /// only once the project model has loaded: while it loads, and after a
    /// failed load, the panel shows a status view with nothing to focus.
    /// Targets and Schemes have no search field.
    var hasSearchField: Bool {
        guard loadState.model != nil else { return false }
        switch activeTab {
        case .files, .buildSettings:
            return true
        case .targets, .schemes:
            return false
        }
    }

    /// Moves keyboard focus into the active tab's search field.
    ///
    /// The request is an event posted to the field's view, not state kept on
    /// the panel, so a repeated Cmd+F focuses the field again after focus has
    /// moved away.
    ///
    /// - Returns: `true` when the active tab has a search field to focus, so
    ///   the shortcut is handled; `false` otherwise, leaving routing to fall
    ///   through as it does for any panel without find.
    @discardableResult
    func startFind() -> Bool {
        guard hasSearchField else { return false }
        NotificationCenter.default.post(name: .projectPanelSearchFocus, object: id)
        return true
    }
}

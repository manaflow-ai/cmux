import AppKit

/// Capability adopted by panels that can service the global Cmd+F find command.
///
/// cmux owns a single Find menu / Cmd+F shortcut that ``TabManager`` dispatches.
/// Terminal and browser panels are handled by their own bespoke find UI; every
/// other panel type opts in by conforming to this protocol so the command is no
/// longer silently swallowed. Each panel implements find with whatever search UI
/// it already has (an AppKit `NSTextView` find bar, a filter text field, etc.),
/// keeping the routing panel-local and the blast radius small.
@MainActor
protocol FindablePanel: AnyObject {
    /// Whether the panel currently has a text selection usable as the find
    /// needle (drives "Use Selection for Find" / Cmd+E enablement).
    var hasSelectionForFind: Bool { get }

    /// Whether the panel's find UI is currently visible (drives "Hide Find Bar"
    /// menu enablement). Should reflect real UI state where the platform exposes
    /// it, rather than a flag that can drift from the actual bar.
    var isFindVisible: Bool { get }

    /// Opens (or focuses) the panel's find UI.
    /// - Returns: `true` when the panel handled the request, `false` when it has
    ///   nothing to find in its current state so the command should fall through.
    @discardableResult
    func startFind() -> Bool

    /// Advances to the next search result.
    func findNext()

    /// Moves to the previous search result.
    func findPrevious()

    /// Closes or hides the panel's find UI.
    func hideFind()

    /// Seeds the find query from the current selection ("Use Selection for Find").
    func useSelectionForFind()
}

extension FindablePanel {
    /// Most panels do not expose a selection that can seed the find query.
    var hasSelectionForFind: Bool { false }

    /// Panels whose find UI is a permanent control (e.g. an always-present filter
    /// field) report no dismissible find bar.
    var isFindVisible: Bool { false }

    /// Panels without result navigation (e.g. a live filter field) ignore this.
    func findNext() {}

    /// Panels without result navigation (e.g. a live filter field) ignore this.
    func findPrevious() {}

    /// Panels with no dismissible find UI ignore this.
    func hideFind() {}

    /// Panels that cannot seed a query from the selection ignore this.
    func useSelectionForFind() {}
}

extension NSTextFinder.Action {
    /// An `NSMenuItem` whose `tag` matches this action's raw value, suitable as
    /// the `sender` for `NSTextView.performTextFinderAction(_:)` — which reads
    /// the find action from the sender's tag. Centralizes the otherwise
    /// duplicated menu-item construction at each find call site.
    var menuItemSender: NSMenuItem {
        let item = NSMenuItem()
        item.tag = rawValue
        return item
    }
}

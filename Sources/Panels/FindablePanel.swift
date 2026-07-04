import AppKit

/// Capability for panels that can receive global find commands routed by `TabManager`.
@MainActor
protocol FindablePanel: AnyObject {
    /// Whether the panel currently has, or is about to show, an AppKit find UI.
    var isFindVisible: Bool { get }

    /// Whether the panel has a text selection that can seed the find query.
    var hasSelectionForFind: Bool { get }

    /// Starts or focuses the panel's find UI.
    @discardableResult
    func startFind() -> Bool

    /// Advances to the next find result.
    func findNext()

    /// Moves to the previous find result.
    func findPrevious()

    /// Hides the panel's find UI when supported.
    func hideFind()

    /// Uses the current selection as the find query when supported.
    func useSelectionForFind()
}

extension FindablePanel {
    /// Panels opt in when they can track local AppKit find UI visibility.
    var isFindVisible: Bool { false }

    /// Panels opt in when they can derive a find query from local selection.
    var hasSelectionForFind: Bool { false }

    /// Panels that do not expose selection-based find ignore the command.
    func useSelectionForFind() {}
}

extension NSTextFinder.Action {
    /// Menu-item sender shape expected by AppKit text finder responder actions.
    var menuItemSender: NSMenuItem {
        let item = NSMenuItem()
        item.tag = rawValue
        return item
    }

    /// Action to queue when the text view that owns the AppKit finder is not mounted yet.
    var queuedWithoutTextView: NSTextFinder.Action {
        switch self {
        case .nextMatch, .previousMatch:
            return .showFindInterface
        default:
            return self
        }
    }

    func updatesFindVisibility(_ current: Bool) -> Bool {
        switch self {
        case .showFindInterface:
            return true
        case .hideFindInterface:
            return false
        default:
            return current
        }
    }
}

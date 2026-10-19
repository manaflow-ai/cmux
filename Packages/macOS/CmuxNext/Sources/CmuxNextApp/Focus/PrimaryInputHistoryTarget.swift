import AppKit

/// A surface whose primary input keeps a history of what the person sent
/// (Home's message box): a plain Up or Down arrow while the surface has the
/// keyboard but its primary input does not (after a pane-focus shortcut, a
/// click on the transcript, a window switch) focuses the input and recalls a
/// sent message, as the input's own Up does (Lawrence 2026-10-19: "Up arrow
/// ... We need to handle unfocus as well so that, like it is history").
///
/// It is the arrow-key half of ``PrimaryInputTarget``'s printable-key
/// redirect and runs from the same key dispatcher step
/// (`KeyRouter.recallsPrimaryInputHistory`). A separate protocol so a surface
/// opts in to arrows on its own: a primary input without history (an app
/// screen's field) keeps arrows where they are. A view that wraps the surface
/// (the docked Home, a Home tab) conforms by forwarding.
@MainActor
protocol PrimaryInputHistoryTarget: AnyObject {
    /// Whether a plain Up or Down from `responder` (the window's first
    /// responder now) belongs to the history: no from a text input (the
    /// primary input itself recalls through its own key handling), a list that
    /// moves with the arrow keys, or a text selection.
    func historyTakesArrowKeys(from responder: NSResponder?) -> Bool
    /// Focuses the primary input and steps the history: Up (`older`) shows a
    /// sent message, Down steps back toward the kept draft. Returns whether
    /// the input took the key.
    func recallHistory(older: Bool) -> Bool
}

extension TabContent {
    /// The content's history target, when its view (an internal page's
    /// provider view) declares one.
    @MainActor var historyTarget: (any PrimaryInputHistoryTarget)? {
        if case .page(let page) = self { return page.content as? any PrimaryInputHistoryTarget }
        return view as? any PrimaryInputHistoryTarget
    }
}

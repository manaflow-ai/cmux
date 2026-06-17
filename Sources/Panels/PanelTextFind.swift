import AppKit

/// A panel that can present an in-pane Find UI (Cmd+F) backed by an
/// `NSTextView` find bar.
///
/// `Cmd+F` is intercepted globally by `KeyEventMonitor` and routed through
/// `TabManager.startSearch()`. Terminal panels (manaflow-ai/cmux#158) and
/// browser panels have bespoke find implementations; every *other* focused
/// panel previously dropped the keystroke silently — there was no find bar and
/// no feedback (manaflow-ai/cmux#6050, #6049). Panels that conform here opt the
/// focused pane into that same global `Cmd+F` action.
@MainActor
protocol TextFindablePanel: AnyObject {
    /// Present the panel's Find UI, focusing whatever responder hosts it.
    ///
    /// - Returns: `true` when this panel owns the Find action for its current
    ///   state (so the keystroke is considered handled), `false` when it cannot
    ///   currently offer find (and the shortcut should fall through).
    @discardableResult
    func startTextFind() -> Bool
}

extension NSTextView {
    /// Focuses this text view and opens its inline find bar, mirroring a Cmd+F
    /// press while the text view is first responder.
    ///
    /// The global Cmd+F handler swallows the keystroke before AppKit's standard
    /// responder-chain routing can reach the text view, so we invoke
    /// `performFindPanelAction(_:)` directly with the `showFindPanel` tag.
    ///
    /// - Returns: `true` when the find bar was presented, `false` when the text
    ///   view is not yet in a window (so the caller can retry once it attaches).
    @discardableResult
    func cmuxPresentInlineFindBar() -> Bool {
        guard let window else { return false }
        usesFindBar = true
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        let trigger = NSMenuItem()
        trigger.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        performFindPanelAction(trigger)
        return true
    }
}

public import AppKit

/// Closed New Tab pages on their way back to the spare pool (CmuxNextApp's `NewTabSparePool`). A pane drops a closed
/// tab's page in the close's turn; the pool gets it only when the tab's release comes, after the store's answer.
/// Between the two the page waits here, in the pool's parking view, so it never leaves its window.
///
/// Why: a WKWebView that joins a window from outside costs a 15-23 ms commit on the main thread; a move between two
/// views of one window costs about 1 ms (Cmd-T's adoption is that move, the other way). A page that left the window
/// had to come back at some turn: in the close's frame it dropped a frame on every Cmd-W (R81), at the next quiet
/// moment it left the pool with a spare in no window, and a Cmd-T before that moment paid the attach in the key's
/// turn. Chromium hands out a spare as it is (`SpareRenderProcessHostManagerImpl::MaybeTakeSpare` checks that the
/// host is initialized and was not used) and has no spare whose cost depends on what it did before; this is the same
/// rule for the view: every spare is in the window, and every Cmd-T does the same one move.
@MainActor
public final class AgentPaneSpareReturns {
    private struct Waiting {
        weak var view: AgentPaneView?
        let since: ContinuousClock.Instant
    }

    private var waiting: [Waiting] = []

    public init() {}

    /// Moves `view` from its pane into `parking` when both are in `window`: one move inside the window. False (and
    /// no move) for a page of another window or a parking view that is not in `window`: that page leaves its window.
    public func keep(_ view: AgentPaneView, in parking: NSView, of window: NSWindow?) -> Bool {
        guard let window, view.window === window, parking.window === window else { return false }
        expire(after: Self.limit, in: parking)
        waiting.removeAll { $0.view == nil || $0.view === view }
        yieldKeyboard(of: view, in: window)
        parking.addSubview(view)
        waiting.append(Waiting(view: view, since: .now))
        return true
    }

    /// The pool takes `view` as a spare now: true when it is in `parking`, or in a pane of `window` (its tab's release
    /// came before its pane dropped it), which moves it there now, inside the window. It is sized with the parking
    /// view as every spare, and waits no more. False for a page of another window or of none: the pool holds no
    /// spare that a Cmd-T would attach to the window in the key's turn.
    public func arrived(_ view: AgentPaneView, in parking: NSView, of window: NSWindow?) -> Bool {
        waiting.removeAll { $0.view == nil || $0.view === view }
        if view.superview !== parking {
            guard let window, view.window === window, parking.window === window else { return false }
            yieldKeyboard(of: view, in: window)
            parking.addSubview(view)
        }
        if view.frame != parking.bounds { view.frame = parking.bounds }
        view.autoresizingMask = [.width, .height]
        return true
    }

    /// A page out of sight never holds the keyboard (as `AgentPageRetirer`'s parking): the removal from the window
    /// that these moves replace took it away too. Without this, keys go into a hidden spare, and the next Cmd-T shows it.
    private func yieldKeyboard(of view: AgentPaneView, in window: NSWindow) {
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) { window.makeFirstResponder(nil) }
    }

    /// How long a kept page waits for its tab's release before it leaves the window.
    public static let limit: Duration = .seconds(2)

    /// A page kept more than `limit` ago that the pool did not take (its tab's release never came, or the pane went
    /// away with a tab that lives on) leaves `parking`, as a dropped page did before.
    public func expire(after limit: Duration, in parking: NSView) {
        let now = ContinuousClock.now
        waiting.removeAll { entry in
            guard let view = entry.view else { return true }
            guard now - entry.since > limit else { return false }
            if view.superview === parking { view.removeFromSuperview() }
            return true
        }
    }
}

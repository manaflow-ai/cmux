public import AppKit

/// A prewarmed New Tab page opens an existing chat (a sidebar click, Open in Tab, a subagent's
/// pane): the page is loaded, mounted and connected to acpmux already, so it switches to the
/// chat in place (the switch `chat.select` makes, drawing a kept tail from `chat.tail.get` when
/// the host has one) instead of a new page loading, connecting and attaching cold.
///
/// It never shows its New Tab screen in the chat's pane, not for one frame. The page leaves that
/// screen in the event's own render (`acpmux-session-adopt`, newtab/adoption.ts), and until it
/// reports the chat drawn (`pane.painted`) the pane shows its cover (the loading state, or the
/// tab's saved frame from the last quit) with the page laid out outside the window: a Chromium
/// page draws in its own window over the pane, which no cover under it and no alpha hides.
extension AgentPaneView {
    /// How far outside the window a held page lies (as the New Tab spare's parking).
    static let awayOffset: CGFloat = -100_000

    static func awayFrame(of frame: NSRect) -> NSRect { frame.offsetBy(dx: awayOffset, dy: awayOffset) }

    /// Adopts this connected New Tab page for the tab of chat `session`; `revealTurn` is a turn its
    /// open asks to show (a subagent's pane: `subagent:<id>`). `moved` runs each time the held page
    /// changes place (out of the window now, back once it drew), so a Chromium page's window follows.
    /// False when the page is no untouched, connected New Tab page (``AgentPaneModel/adoptSpareSession(_:)``).
    @discardableResult
    public func adoptSession(_ session: String, revealTurn: String? = nil, moved: (@MainActor () -> Void)? = nil) -> Bool {
        guard model.adoptSpareSession(session) else { return false }
        holdPageAway(moved: moved)
        beginLoadingState()
        // A New Tab page drew without it (AgentTabStore.makeView); the chat's pane keeps it until it drew.
        showsLoadingState = true
        // The chat's surface (R55), not the New Tab page's; the loading state takes its color.
        applyTheme()
        var detail: [String: Any] = ["sessionId": session]
        if let revealTurn { detail["revealTurn"] = revealTurn }
        guard let data = try? JSONSerialization.data(withJSONObject: detail, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return true }
        evaluateScript("window.dispatchEvent(new CustomEvent('acpmux-session-adopt', {detail: \(json)}))")
        return true
    }

    /// Lays the page outside the window now, before the pane shows this view, and back in place in
    /// the turn it reports the chat drawn (or the loading state's give-up marks it painted).
    private func holdPageAway(moved: (@MainActor () -> Void)?) {
        holdsPageAway = true
        pageContent.frame = Self.awayFrame(of: topBar.contentFrame(in: bounds))
        moved?()
        model.whenPainted { [weak self] in
            guard let self, holdsPageAway else { return }
            holdsPageAway = false
            pageContent.frame = topBar.contentFrame(in: bounds)
            needsLayout = true
            moved?()
        }
    }
}

public import AppKit
import CmuxNextSettings

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
        // A New Tab page drew without it (AgentTabStore.makeView); the chat's pane keeps it until it drew.
        // On before the loading state begins: that is where the chat-open trace binds and takes its
        // first sample, which would otherwise read the New Tab page's hidden cover as the chat's saved
        // frame and count the cover that follows in the same turn as a flash (cmux#32448).
        showsLoadingState = true
        beginLoadingState()
        // The chat's surface (R55), not the New Tab page's; the loading state takes its color.
        applyTheme()
        // The chat's kept tail rides on the event: the page draws it in the event's own render,
        // where asking for it (`chat.tail.get`) cost a round trip a busy main thread lost to its
        // 250 ms race, leaving the pane empty until acpmux's attach answered.
        let json = Self.adoptEventDetail(session: session, revealTurn: revealTurn, tail: AgentPaneTailCache.shared.tail(for: session))
        evaluateScript("window.dispatchEvent(new CustomEvent('acpmux-session-adopt', {detail: \(json)}))")
        return true
    }

    /// The adopt event's detail as JSON text (newtab/adoption.ts `sessionAdoption` reads it): the chat,
    /// the turn its open asks to show, and the chat's tail the host keeps (``AgentPaneTailCache``), in
    /// the page's own shape, when it holds one. Linear in the tail's size, which the cache bounds.
    nonisolated static func adoptEventDetail(session: String, revealTurn: String?, tail: JSONValue?) -> String {
        var detail: [String: JSONValue] = ["sessionId": .string(session)]
        if let revealTurn { detail["revealTurn"] = .string(revealTurn) }
        if let tail { detail["tail"] = tail }
        return JSONValue.object(detail).compactText
    }

    /// Tells the page the tab it now is (``AgentPaneModel/tabKey``, on each change), for a page a tab
    /// adopted after its handshake (a prewarmed spare): it keeps its Session Info by that tab from here
    /// (`acpmux-pane-tab`, sessionInfoState.ts). A page with no handshake yet gets it with its handshake.
    func announceTab() {
        guard model.hasHandshake, let tab = model.tabKey(),
              let data = try? JSONSerialization.data(withJSONObject: ["tab": tab], options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluateScript("window.dispatchEvent(new CustomEvent('acpmux-pane-tab', {detail: \(json)}))")
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
            applyNativeRects() // the tab row's holes, taken while it was away, follow it back
            needsLayout = true
            moved?()
        }
    }
}

public import AppKit
public import CmuxNextPages

/// Up and Down from outside a Messages page (Lawrence 2026-10-19: "Up arrow ... handle unfocus as
/// well"; the native HomeHostView+PrimaryInputHistory): while the pane has the keyboard outside the
/// page (no responder after a pane-focus shortcut, the pane itself), a plain Up or Down focuses the
/// page's message box and steps its sent-message history. Inside the page the page does the same
/// itself (composerHandoff.ts `recallFromOutside`), so a field, a list or a text selection keeps its arrows.
extension HomeComposerHandoff {
    /// The box takes the keyboard and recalls an older (`older`) or newer sent message.
    public func recallHistory(older: Bool) async {
        _ = await call("home.messages.recallHistory", ["older": .bool(older)], within: Self.answerDeadline)
    }

    /// A plain Up (true) or Down (false) while `page`'s window has the keyboard outside it; nil for
    /// any other key, a chord, or a key inside the page (the page handles its own).
    public static func historyArrow(_ event: NSEvent, outside page: NSView) -> Bool? {
        guard event.type == .keyDown, event.keyCode == 126 || event.keyCode == 125, let window = page.window else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        guard flags.isEmpty else { return nil }
        if let view = window.firstResponder as? NSView, view === page || view.isDescendant(of: page) { return nil }
        return event.keyCode == 126
    }
}

extension HomeComposerHosting {
    /// `event`, a history arrow from outside `page` (``HomeComposerHandoff/historyArrow(_:outside:)``):
    /// the page takes the keyboard and its box steps the history.
    public func recallHistory(_ event: NSEvent, page: PageWebView) {
        guard let older = HomeComposerHandoff.historyArrow(event, outside: page) else { return }
        let handoff = composerHandoff
        page.focusPage()
        // task-owner: one page call; ends with its answer or the deadline
        // main-hop-allow: already on main (a key); the task only awaits the page's answer
        Task { @MainActor in await handoff.recallHistory(older: older) }
    }
}

/// A toast never covers the chat (Leo, 2026-11-06: "why is this still happening yo"). Toasts rest
/// bottom-center over the window, over a Messages page's foot where its composer is; the view that
/// holds the page (``CmuxToastReserving``) hands it each settle, and this gives the page the band
/// they take (`__cmuxToastRoom`, webviews agent-session/acpmux/toastRoom.ts); the page keeps its
/// transcript and composer above it.
@MainActor
public final class HomePageToastRoom {
    private weak var page: PageWebView?
    private var toasts: NSRect?
    private var sent: Double = 0
    /// The gap between the toasts' top and the composer above them.
    nonisolated static let gap: CGFloat = 8

    public init(page: PageWebView) {
        self.page = page
    }

    /// The window's toasts settled in `rect` (window coordinates; nil: none); the page slides over `duration`.
    public func settled(_ rect: NSRect?, duration: TimeInterval) {
        toasts = rect
        send(duration: duration)
    }

    /// The page was laid out (a resize, a move in its window): the band follows at once.
    public func follow() {
        if toasts != nil || sent != 0 { send(duration: 0) }
    }

    private func send(duration: TimeInterval) {
        guard let page else { return }
        let pane = page.window == nil ? NSRect.zero : page.convert(page.bounds, to: nil)
        let points = Self.band(toasts: toasts, pane: pane) / max(page.pageZoom, 0.01)
        let room = points.isFinite ? (Double(points) * 100).rounded() / 100 : 0
        guard room != sent else { return }
        sent = room
        let ms = duration.isFinite ? Int((max(0, duration) * 1000).rounded()) : 0
        page.evaluate("globalThis.__cmuxToastRoom?.(\(room), \(ms));")
    }

    /// The band at the foot of `pane` (window coordinates) that toasts in `toasts` take, in view
    /// points: from the pane's bottom to the toasts' top and a gap; 0 when no toast lies over the
    /// pane. Never more than half the pane, so a short pane keeps its chat.
    nonisolated static func band(toasts: NSRect?, pane: NSRect) -> CGFloat {
        guard let toasts, !toasts.isEmpty, !pane.isEmpty, toasts.maxX > pane.minX, toasts.minX < pane.maxX,
              toasts.minY < pane.maxY, toasts.maxY > pane.minY else { return 0 }
        return min(pane.height / 2, toasts.maxY + gap - pane.minY)
    }
}

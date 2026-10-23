import AppKit

/// Pointer moves while a hover card shows: the card ignores the mouse, so over it no source sees
/// the pointer leave it; this watch's monitor sees it at once (no wait for a deadline).
///
/// While it watches, the card's parent window takes mouse moves everywhere (so moves over the card
/// reach the monitor); ``end()`` gives the parent back its own setting. A main-actor class, so the
/// coordinator's nonisolated `deinit` can pass it to the main thread
/// (`MainDelivery().run { watch.end() }`) and a coordinator released while a card shows leaves
/// neither the monitor nor the parent's setting behind.
@MainActor
final class HoverCardMoveWatch {
    /// The `.mouseMoved` local monitor, installed by the coordinator with its handler.
    let monitor: LocalEventMonitor
    /// The card's parent and whether it took mouse moves before the watch set it.
    private var parent: (window: NSWindow, accepted: Bool)?

    /// Holds `monitor` (removed by ``end()``); no parent takes mouse moves until ``follow(_:)``.
    init(monitor: LocalEventMonitor) {
        self.monitor = monitor
    }

    /// The card's parent is `window` now: it takes mouse moves, and a previous parent gets its
    /// own setting back.
    func follow(_ window: NSWindow) {
        guard parent?.window !== window else { return }
        restoreParent()
        parent = (window, window.acceptsMouseMovedEvents)
        window.acceptsMouseMovedEvents = true
    }

    /// Gives the parent back its setting and removes the monitor; later calls do nothing.
    func end() {
        restoreParent()
        monitor.remove()
    }

    private func restoreParent() {
        if let old = parent { old.window.acceptsMouseMovedEvents = old.accepted }
        parent = nil
    }
}

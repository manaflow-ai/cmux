public import AppKit
import os

/// The Chief pane's ask for the brain host: a Chief chat whose acpmux socket answers nothing asks its owner
/// to start (`AcpmuxHost`'s `startOwner`, ``ChiefBrainKeeper/ensureForChat()``), so a restored Chief chat
/// connects after a relaunch without Home being shown (#25570). The Home workspace's Chief tab is such a
/// chat, made at every launch whether or not Home is on screen.
///
/// With ``HomeShownWatch/waitsForScreen`` (`CMUX_NEXT_CHIEF_START=visible`) the ask starts the host only
/// when one of the Chief panes is on screen; otherwise it answers false (the pane says the Chief is not
/// running, which its page retries on its own) and starts the host once one of them shows
/// (``HomeShownWatch/whenOnScreen(_:_:)``). A Chief chat the person opens is on screen, so it starts at
/// once. Unset: every ask starts it, as before. The first ask, and every ask with a pane on screen, logs
/// `chief start asked from chief_pane on_screen <bool> panes <n>`.
@MainActor
public final class ChiefPaneStartGate {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")
    private var asks = 0

    public init() {}

    /// One ask. `panes`: the Chief chat views this app has now; `start`: the brain host's start
    /// (whether one runs or is starting afterwards).
    public func ask<Pane: NSView>(panes: [Pane], start: @escaping @MainActor () -> Bool) -> Bool {
        asks += 1
        let shown = panes.contains { HomeShownWatch.isOnScreen($0) }
        if asks == 1 || shown {
            Self.logger.notice("chief start asked from chief_pane on_screen \(shown, privacy: .public) panes \(panes.count, privacy: .public) asks \(self.asks, privacy: .public) waits_for_screen \(HomeShownWatch.waitsForScreen, privacy: .public)")
        }
        guard HomeShownWatch.waitsForScreen, !shown else { return start() }
        for pane in panes { HomeShownWatch.whenOnScreen(pane) { _ = start() } }
        return false
    }
}

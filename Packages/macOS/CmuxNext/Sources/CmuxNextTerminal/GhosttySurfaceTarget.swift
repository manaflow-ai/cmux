import AppKit
import CmuxNextWakeups

/// What one surface's Ghostty callbacks reach on the main actor (``SurfaceBridge/target``): its
/// ``TerminalSurfaceView`` in the app, a recorder in a test. The bridge calls each of these after the
/// surface's waiting state actions (``SurfaceBridge/flushActions()``), so each sees the state Ghostty
/// sent before it.
@MainActor protocol GhosttySurfaceTarget: AnyObject {
    /// The frame scheduler of the window the surface shows in: its state actions wait for that frame.
    var actionFrameScheduler: FrameScheduler { get }
    /// The node of the tab the surface shows in: while nobody sees it, its state actions wait for it to
    /// show. Nil (the default): they apply whether or not anyone sees the surface.
    var actionNode: VisibilityNode? { get }
    /// Applies a surface action (``TerminalSurfaceView/applyAction(_:)``); false: not handled.
    func applyAction(_ action: GhosttyAction) -> Bool
    /// Runs an app-level action a keybind on the surface asked for; false: not handled.
    func handleHostAction(_ action: TerminalHostAction) -> Bool
    /// An unsafe paste or a clipboard read or write that needs the person's consent.
    func confirmClipboard(contents: String, contentBytes: Int, kind: TerminalClipboardRequestKind, state: UncheckedPointer)
    /// A program's or a keybind's clipboard write.
    func writeClipboard(items: [TerminalClipboardItem], location: TerminalPasteboardLocation, requiresConfirmation: Bool)
    /// The surface's program asked to close it.
    func surfaceRequestedClose()
}

extension GhosttySurfaceTarget {
    var actionNode: VisibilityNode? { nil }
}

extension TerminalSurfaceView: GhosttySurfaceTarget {
    var actionFrameScheduler: FrameScheduler { FrameScheduler.forView(self) }
    /// The tab node of the session's host (`TabContentCache.node(for:)`) while the runtime holds hidden
    /// terminals' actions (feature `terminalHiddenActionHold`); nil without a tab or with the feature off.
    var actionNode: VisibilityNode? { GhosttyRuntime.shared.holdsHiddenActions ? session?.view.node : nil }

    func confirmClipboard(contents: String, contentBytes: Int, kind: TerminalClipboardRequestKind, state: UncheckedPointer) {
        clipboardRequests.confirm(contents: contents, contentBytes: contentBytes, kind: kind, state: state)
    }

    func writeClipboard(items: [TerminalClipboardItem], location: TerminalPasteboardLocation, requiresConfirmation: Bool) {
        clipboardRequests.write(items: items, location: location, requiresConfirmation: requiresConfirmation)
    }
}

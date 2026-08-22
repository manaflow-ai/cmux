import AppKit

// Cmd+Z / Cmd+Shift+Z for browser web views.
//
// WebKit registers every web-content edit command on the web view's
// `undoManager` (`WebViewImpl::registerEditCommand` calls
// `[m_view undoManager]`). NSResponder's default implementation resolves that
// to the window's shared undo manager, which mixes edit commands from every
// web view in the window into one stack whose registered targets can outlive
// their web view — the stale-target crash behind
// https://github.com/manaflow-ai/cmux/issues/7272. The fix for that crash
// routes the undo/redo chords away from the AppKit Edit menu whenever a
// browser web view is focused, which also silenced in-page undo/redo because
// nothing performed the command anymore
// (https://github.com/manaflow-ai/cmux/issues/9677).
//
// Owning an undo manager per web view restores both invariants:
// - web-content edit commands never reach the window's shared undo manager
//   and never outlive their web view, so the stale-target class of crashes is
//   impossible by construction;
// - the routed chords can perform undo/redo directly on the focused web
//   view's own stack, matching Safari's Edit-menu behavior.
extension CmuxWebView {
    override var undoManager: UndoManager? { webContentUndoManager }

    /// Performs the page's native editing undo/redo for a routed
    /// Cmd+Z / Cmd+Shift+Z chord.
    ///
    /// Returns `false` when `event` is not an undo/redo command equivalent.
    /// Otherwise the chord is consumed even when the relevant stack is empty,
    /// mirroring a disabled Edit-menu item rather than re-forwarding the key.
    func performWebContentUndoRedo(for event: NSEvent) -> Bool {
        guard event.cmuxIsUndoRedoCommandEquivalent else { return false }
        let isRedo = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)
#if DEBUG
        cmuxDebugLog(
            "browser.webContentUndoRedo \(isRedo ? "redo" : "undo") " +
            "web=\(ObjectIdentifier(self)) " +
            "canUndo=\(webContentUndoManager.canUndo ? 1 : 0) " +
            "canRedo=\(webContentUndoManager.canRedo ? 1 : 0)"
        )
#endif
        if isRedo {
            if webContentUndoManager.canRedo {
                webContentUndoManager.redo()
            }
        } else if webContentUndoManager.canUndo {
            webContentUndoManager.undo()
        }
        return true
    }
}

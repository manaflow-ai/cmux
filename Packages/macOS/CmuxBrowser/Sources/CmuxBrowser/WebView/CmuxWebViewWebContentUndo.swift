public import AppKit
import CMUXDebugLog
public import WebKit

/// Base class for every WebKit view that cmux embeds in an app window.
///
/// WebKit registers page edit commands through the view's `undoManager`.
/// `NSResponder` otherwise resolves that property to the window's shared
/// manager, which lets commands from a closed web view remain in a different
/// object's undo stack and later message a dangling target.
open class CmuxUndoableWebView: WKWebView {
    public let webContentUndoManager = UndoManager()

    // WebKit reads the responder's undo manager from framework callbacks; do
    // not make that Objective-C getter enter a Swift MainActor check.
    open nonisolated override var undoManager: UndoManager? { webContentUndoManager }

    /// Whether `event` is the keyboard-layout-aware Cmd+Z or Cmd+Shift+Z
    /// chord this view completes. The keyboard layout lookup lives in the
    /// app, so each concrete web view class overrides this; the base class
    /// recognizes no chord.
    open func isWebContentUndoRedoCommandEquivalent(_ event: NSEvent) -> Bool {
        false
    }

    /// Completes a routed WebKit undo command after the page declines it.
    open override func keyDown(with event: NSEvent) {
        if performWebContentUndoRedo(for: event) {
            return
        }
        super.keyDown(with: event)
    }
}

extension NSWindow {
    /// Finds an embedded WebKit view from a responder without depending on
    /// browser-only panel state. Agent-session and Markdown views use this
    /// path when their web content owns first responder.
    public func cmuxOwningUndoableWebView(for responder: NSResponder) -> CmuxUndoableWebView? {
        if let webView = responder as? CmuxUndoableWebView {
            return webView
        }
        if let view = responder as? NSView {
            var current: NSView? = view.superview
            while let candidate = current {
                if let webView = candidate as? CmuxUndoableWebView {
                    return webView
                }
                current = candidate.superview
            }
        }
        var current = responder.nextResponder
        var hops = 0
        while let next = current, hops < 64 {
            if let webView = next as? CmuxUndoableWebView {
                return webView
            }
            current = next.nextResponder
            hops += 1
        }
        return nil
    }
}

// Cmd+Z / Cmd+Shift+Z for embedded WebKit views.
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
// Owning an undo manager per WebKit view restores both invariants:
// - web-content edit commands never reach the window's shared undo manager
//   and never outlive their web view, so the stale-target class of crashes is
//   impossible by construction;
// - the routed chords can perform undo/redo directly on the focused web
//   view's own stack, matching Safari's Edit-menu behavior.
extension CmuxUndoableWebView {
    /// Performs the page's native editing undo/redo for a routed
    /// Cmd+Z / Cmd+Shift+Z chord.
    ///
    /// Returns `false` when `event` is not an undo/redo command equivalent.
    /// Otherwise the chord is consumed even when the relevant stack is empty,
    /// mirroring a disabled Edit-menu item rather than re-forwarding the key.
    ///
    /// Browser automation's keys (``NSEvent/isBrowserAutomationKeyEvent``:
    /// a REPL session's, `cmux browser press`') are never consumed here:
    /// they go to WebKit, so the page gets the keydown first and can cancel
    /// it, and only a key no page handled runs Undo or Redo afterwards. The
    /// REPL runs it through the frame gate, which refuses a focused frame
    /// or document the session's authority blocks; done here, the undo
    /// would reach the tab's last edit wherever the focus is.
    public func performWebContentUndoRedo(for event: NSEvent) -> Bool {
        guard !event.isBrowserAutomationKeyEvent, isWebContentUndoRedoCommandEquivalent(event) else { return false }
        let isRedo = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)
        performWebContentUndoRedo(redo: isRedo)
        return true
    }

    /// Undoes or redoes the web view's last edit on its own undo stack, if
    /// there is one.
    public func performWebContentUndoRedo(redo isRedo: Bool) {
#if DEBUG
        CMUXDebugLog.logDebugEvent(
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
    }
}

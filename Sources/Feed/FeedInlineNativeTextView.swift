import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxFoundation
import Foundation
import SwiftUI

final class FeedInlineNativeTextView: NSTextView, FeedScopedKeyboardFocusResponder {
    private static weak var activeEditor: FeedInlineNativeTextView?

    var onActivate: (() -> Void)?
    var onEscape: (() -> Void)?
    var onSubmit: (() -> Void)?
    var feedFocusScopeID = UUID()

    static func blurActiveEditor(in hostWindow: NSWindow?) {
        guard let activeEditor else { return }
        guard let window = activeEditor.window else {
            if Self.activeEditor === activeEditor {
                Self.activeEditor = nil
            }
            return
        }
        guard window === hostWindow else { return }
        guard window.firstResponder === activeEditor else {
            if Self.activeEditor === activeEditor {
                Self.activeEditor = nil
            }
            return
        }
#if DEBUG
        dlog("feed.editor.blurActive fr=\(feedDebugResponderSummary(window.firstResponder))")
#endif
        window.makeFirstResponder(nil)
    }

    override func mouseDown(with event: NSEvent) {
#if DEBUG
        dlog("feed.editor.mouseDown frBefore=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
        onActivate?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 {
#if DEBUG
            dlog("feed.editor.escape fr=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
            onEscape?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shouldSubmit = (event.keyCode == 36 || event.keyCode == 76)
            && normalizedFlags.intersection([.shift, .option, .command, .control]).isEmpty
        if shouldSubmit, !hasMarkedText(), let onSubmit {
            onSubmit()
            return
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            Self.activeEditor = self
            onActivate?()
        }
#if DEBUG
        dlog("feed.editor.become result=\(didBecomeFirstResponder ? 1 : 0) fr=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder, Self.activeEditor === self {
            Self.activeEditor = nil
        }
#if DEBUG
        dlog("feed.editor.resign result=\(didResignFirstResponder ? 1 : 0) fr=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
        return didResignFirstResponder
    }
}

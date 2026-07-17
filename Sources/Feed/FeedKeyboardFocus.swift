import AppKit
import Bonsplit
import CMUXAgentLaunch
import Foundation
import SwiftUI

final class FeedKeyboardFocusView: NSView, FeedScopedKeyboardFocusResponder {
    var placement: FeedPlacement = .rightSidebar
    var feedFocusScopeID = UUID()
    var onEscape: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onActivateSelection: (() -> Void)?
    var onFocusFirstItemRequested: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var onFocusSnapshotChanged: ((FeedFocusSnapshot) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWithKeyboardFocusCoordinatorIfNeeded()
#if DEBUG
        if let window {
            dlog("feed.focus.host attach window=\(ObjectIdentifier(window)) placement=\(placement)")
        }
#endif
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard placement.usesRightSidebarFocusCoordinator, let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerFeedHost(self)
    }

    override func layout() {
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 {
#if DEBUG
            dlog(
                "feed.focus.host escape window=\(window.map { String(describing: ObjectIdentifier($0)) } ?? "nil") " +
                "fr=\(feedDebugResponderSummary(window?.firstResponder))"
            )
#endif
            onEscape?()
            return true
        }
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            onMoveSelection?(delta)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
#if DEBUG
        dlog(
            "feed.focus.host keyDown key=\(event.keyCode) modifiers=\(event.modifierFlags.rawValue) " +
            "fr=\(feedDebugResponderSummary(window?.firstResponder))"
        )
#endif
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }

        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            onMoveSelection?(delta)
            return
        }

        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasShortcutModifier = !normalizedFlags.intersection([.command, .control, .option]).isEmpty
        guard !hasShortcutModifier else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 36, 76:
            onActivateSelection?()
            return
        case 53:
            onEscape?()
            return
        default:
            break
        }

        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocusChanged?(true)
        }
#if DEBUG
        dlog(
            "feed.focus.host become result=\(result ? 1 : 0) " +
            "window=\(window.map { String(describing: ObjectIdentifier($0)) } ?? "nil") " +
            "fr=\(feedDebugResponderSummary(window?.firstResponder))"
        )
#endif
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            onFocusChanged?(false)
        }
#if DEBUG
        dlog(
            "feed.focus.host resign result=\(result ? 1 : 0) " +
            "window=\(window.map { String(describing: ObjectIdentifier($0)) } ?? "nil") " +
            "fr=\(feedDebugResponderSummary(window?.firstResponder))"
        )
#endif
        return result
    }

    func focusFirstItemFromCoordinator() {
        onFocusFirstItemRequested?()
    }

    func focusHostFromCoordinator() -> Bool {
        guard let window else { return false }
#if DEBUG
        let before = feedDebugResponderSummary(window.firstResponder)
#endif
        let result = window.makeFirstResponder(self)
#if DEBUG
        dlog(
            "feed.focus.host request result=\(result ? 1 : 0) " +
            "window=\(ObjectIdentifier(window)) before=\(before) " +
            "after=\(feedDebugResponderSummary(window.firstResponder))"
        )
#endif
        return result
    }

    func applyFocusSnapshotFromController(_ snapshot: FeedFocusSnapshot) {
        onFocusSnapshotChanged?(snapshot)
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === self { return true }
        guard responder is FeedKeyboardFocusResponder else { return false }
        guard let feedResponder = responder as? FeedScopedKeyboardFocusResponder else {
            // Compatibility for legacy Feed controls that predate pane-scoped focus.
            return true
        }
        return feedResponder.feedFocusScopeID == feedFocusScopeID
    }
}

// MARK: - Row snapshot + actions (respects snapshot-boundary rule)

/// Immutable snapshot of a `WorkstreamItem` handed to row views so rows
/// never hold a reference to the store.

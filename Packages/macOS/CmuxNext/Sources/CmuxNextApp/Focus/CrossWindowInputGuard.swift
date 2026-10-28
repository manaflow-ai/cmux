import AppKit
import os

/// The last check before AppKit delivers a key-down (`CmuxApplication.sendEvent`): AppKit sends
/// every key to the key window, whatever window the key was typed into. When the key window
/// changed between the key press and its dispatch (a late `makeKey`, a key record that went stale),
/// a key typed into one cmux window would land in another. Such a key is dropped and logged,
/// never delivered: no input reaches a cmux window other than the one it was typed into.
///
/// A window belongs to the cmux window that owns it (itself, a sheet, a Chromium page window, a
/// panel over it; `WindowManager.owner(of:)`). Windows no cmux window owns (Settings, a standalone
/// panel) are not judged.
@MainActor
struct CrossWindowInputGuard {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.cross-window")

    /// The cmux window id that owns a window, nil for a window no cmux window owns.
    let owner: (NSWindow) -> String?

    init(windows: WindowManager) {
        owner = { [weak windows] window in windows?.owner(of: window)?.state.id }
    }

    /// True when the key was typed into one cmux window and AppKit would deliver it to another.
    func dropsKey(eventWindow: NSWindow?, keyWindow: NSWindow?) -> Bool {
        guard let eventWindow, let keyWindow, eventWindow !== keyWindow,
              let source = owner(eventWindow), let target = owner(keyWindow) else { return false }
        return source != target
    }

    /// ``dropsKey(eventWindow:keyWindow:)`` for `event`, logging a drop.
    func dropsKey(_ event: NSEvent, keyWindow: NSWindow?) -> Bool {
        guard dropsKey(eventWindow: event.window, keyWindow: keyWindow) else { return false }
        let source = event.window.flatMap(owner) ?? "-", target = keyWindow.flatMap(owner) ?? "-"
        #if DEBUG
        Self.logger.fault("dropped a key typed into window \(source, privacy: .public) that would reach window \(target, privacy: .public)")
        #else
        Self.logger.error("dropped a key typed into window \(source, privacy: .public) that would reach window \(target, privacy: .public)")
        #endif
        return true
    }
}

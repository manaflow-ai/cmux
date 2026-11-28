import AppKit
import CmuxNextDesign
import os

/// The window the key window acts for, its close semantics, and whether
/// the key window is a sheet or panel over it.
struct KeyWindowRole {
    let root: NSWindow
    let close: WindowCloseSemantics
    let overRoot: Bool

    /// Nil when there is no key window of ours (a parentless Chromium page
    /// window) and for the palette opened with no window to sit on (it
    /// acts for the active main window, as it does over one).
    ///
    /// The kind comes from the window kit (`NSWindow.windowKindRoot`). A
    /// window no owner installed acts as a main window when a main window
    /// owns it (palette, sheets). Any other kind-less window (a system
    /// panel, a window a new owner forgot to install) is a window of its
    /// own, the safe default: close actions close it when it has a close
    /// button and do nothing when it has none, and destructive content
    /// actions are off. It never falls through to the main window behind
    /// it. Debug builds log a fault once per such window (the owner must
    /// call `install(kind:content:scope:)`).
    @MainActor
    static func resolve(_ key: NSWindow, ownedByMain: Bool, isPalette: Bool) -> KeyWindowRole? {
        let root = key.windowKindRoot
        // A Chromium page window inside the root (an undocked inspector's
        // page, a popup's page) acts for it.
        let inside = key === root || (key.sheetParent == nil && isChromiumPageWindow(key))
        if let kind = root.windowKind { return KeyWindowRole(root: root, close: kind.traits.close, overRoot: !inside) }
        if ownedByMain { return KeyWindowRole(root: root, close: .contentFirst, overRoot: !inside) }
        if root === key, isChromiumPageWindow(key) { return nil }
        if isPalette { return nil }
        KindlessWindowAudit.note(root)
        let closable = root.styleMask.isSuperset(of: [.titled, .closable])
        return KeyWindowRole(root: root, close: .window, overRoot: !inside || !closable)
    }

    /// `CefNSWindow`: a Chromium page window.
    private static func isChromiumPageWindow(_ window: NSWindow) -> Bool {
        guard let pageClass = NSClassFromString("CefNSWindow") else { return false }
        return window.isKind(of: pageClass)
    }
}

/// Logs (a fault in debug builds, never a crash) the first time each
/// kind-less cmux window acts as the key window (plans/cmux-next/windows.md):
/// its owner must install it through the window kit. AppKit's own panels
/// (About, open and save, font, color), which no owner can install, are
/// logged at debug level only.
@MainActor
enum KindlessWindowAudit {
    private static let seen = NSHashTable<NSWindow>.weakObjects()
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.windows")

    static func note(_ window: NSWindow) {
        guard !seen.contains(window) else { return }
        seen.add(window)
        let name = String(describing: type(of: window))
        if Bundle(for: type(of: window)).bundlePath.hasPrefix("/System/") {
            logger.debug("system window without a kind is key: \(name, privacy: .public)")
            return
        }
        #if DEBUG
        logger.fault("window without a kind is key: \(name, privacy: .public)")
        #else
        logger.error("window without a kind is key: \(name, privacy: .public)")
        #endif
    }
}

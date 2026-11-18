public import AppKit
public import CmuxNextDesign

/// The window the key window acts for, its close semantics, and whether
/// the key window is a sheet or panel over it.
public struct KeyWindowRole {
    /// The window the key window acts for (`NSWindow.windowKindRoot`).
    public let root: NSWindow
    /// What close actions do in it.
    public let close: WindowCloseSemantics
    /// The key window is a sheet or panel over `root`.
    public let overRoot: Bool

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
    /// call `install(kind:content:scope:activeLook:)`).
    ///
    /// - Parameters:
    ///   - key: The key window.
    ///   - ownedByMain: A main window of the app owns it.
    ///   - isPalette: It is the command palette's window.
    /// - Returns: Its role, or nil.
    @MainActor
    public static func resolve(_ key: NSWindow, ownedByMain: Bool, isPalette: Bool) -> KeyWindowRole? {
        let root = key.windowKindRoot
        // A Chromium page window inside the root (an undocked inspector's
        // page, a popup's page) acts for it.
        let inside = key === root || (key.sheetParent == nil && key.isChromiumPageWindow)
        if let kind = root.windowKind { return KeyWindowRole(root: root, close: kind.traits.close, overRoot: !inside) }
        if ownedByMain { return KeyWindowRole(root: root, close: .contentFirst, overRoot: !inside) }
        if root === key, key.isChromiumPageWindow { return nil }
        if isPalette { return nil }
        KindlessWindowAudit.note(root)
        let closable = root.styleMask.isSuperset(of: [.titled, .closable])
        return KeyWindowRole(root: root, close: .window, overRoot: !inside || !closable)
    }
}

public import AppKit

/// Which windows are which ``WindowKind``. Weak keys, like
/// `ThemeScopeRegistry`: an entry lives as long as its window.
@MainActor
enum WindowKindRegistry {
    private static let kinds = NSMapTable<NSWindow, NSString>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    static func kind(of window: NSWindow) -> WindowKind? {
        kinds.object(forKey: window).flatMap { WindowKind(rawValue: $0 as String) }
    }

    static func setKind(_ kind: WindowKind, of window: NSWindow) {
        kinds.setObject(kind.rawValue as NSString, forKey: window)
    }

    /// The window whose kind `window` acts as: `window` itself when it has
    /// a kind, else the nearest window up its `sheetParent ?? parent` chain
    /// that has one, else the top of that chain. A palette, sheet or panel
    /// over a main window resolves to it; a browser popup (a child of its
    /// opener's window with a kind of its own) to itself.
    static func root(of window: NSWindow) -> NSWindow {
        var current = window
        while kind(of: current) == nil, let up = current.sheetParent ?? current.parent { current = up }
        return current
    }
}

extension NSWindow {
    /// This window's own kind; nil when no owner installed it through
    /// ``install(kind:content:scope:)``.
    public var windowKind: WindowKind? { WindowKindRegistry.kind(of: self) }

    /// The window whose kind this window acts as (``WindowKindRegistry``).
    public var windowKindRoot: NSWindow { WindowKindRegistry.root(of: self) }
}

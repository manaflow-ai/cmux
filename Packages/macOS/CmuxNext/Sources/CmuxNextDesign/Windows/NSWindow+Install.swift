public import AppKit

/// A content view that paints its window's one backdrop (material, tint,
/// window opacity and blur: `WindowBackdrop`): ``WindowSurfaceView`` and
/// the main window's root. It repaints on its own theme changes;
/// ``NSWindow/install(kind:content:scope:)`` calls it once before the
/// content view is installed.
public protocol WindowSurfacePainting: NSView {
    func paintWindowSurface(of window: NSWindow)
}

extension NSWindow {
    /// The only way a window gets its content (plans/cmux-next/windows.md):
    /// records `kind`, makes the window titled and closable with the
    /// kind's buttons, adopts `scope`, paints the one backdrop (the main
    /// window's material and tint, in a ``WindowSurfaceView`` around
    /// `content` unless the content paints it itself), and only then sets
    /// `contentView`. Changing the
    /// background while AppKit installs the content view puts the content
    /// above the titlebar and hides the close button, so the order is
    /// fixed here and nowhere else.
    ///
    /// ```swift
    /// window.install(kind: .settings, content: hostingView, scope: scope)
    /// ```
    public func install(kind: WindowKind, content: NSView, scope: ThemeScope) {
        WindowKindRegistry.setKind(kind, of: self)
        let traits = kind.traits
        styleMask.formUnion([.titled, .closable])
        if traits.hidesMinimizeAndZoom {
            standardWindowButton(.miniaturizeButton)?.isHidden = true
            standardWindowButton(.zoomButton)?.isHidden = true
        }
        scope.adopt(self)
        let root: NSView = traits.surface == .backdrop ? WindowSurfaceView(content: content) : content
        (root as? any WindowSurfacePainting)?.paintWindowSurface(of: self)
        contentView = root
    }
}

public import AppKit

/// Content that paints its window's background itself (the main window's
/// root: one material and tint, `WindowBackdrop`). It repaints on its own
/// theme changes; ``NSWindow/install(kind:content:scope:)`` calls it once
/// before the content is installed.
public protocol WindowSurfacePainting: NSView {
    func paintWindowSurface(of window: NSWindow)
}

extension NSWindow {
    /// The only way a window gets its content (plans/cmux-next/windows.md):
    /// records `kind`, makes the window titled and closable with the
    /// kind's buttons, adopts `scope`, sets the background from the one
    /// surface token, and only then sets `contentView`. Changing the
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
        // Adopting paints the kind's surface (`paintKindSurface`).
        scope.adopt(self)
        if traits.surface == .content { (content as? any WindowSurfacePainting)?.paintWindowSurface(of: self) }
        contentView = content
    }

    /// Paints this window's background for its kind in its theme scope.
    /// Theme scopes and the store call it on every theme change. Values
    /// that already match are not written again: a background write after
    /// the content view is installed reorders the titlebar.
    func paintKindSurface() {
        guard let kind = windowKind else { return }
        let color: NSColor
        switch kind.traits.surface {
        case .content: return
        case .clear: color = .clear
        case .token: color = themeScope.perform { Palette.surfaceBackground.withAlphaComponent(1) }
        }
        let opaque = kind.traits.surface == .token
        if isOpaque != opaque { isOpaque = opaque }
        if backgroundColor != color { backgroundColor = color }
    }
}

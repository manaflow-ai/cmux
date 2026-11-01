public import AppKit
public import CmuxNextDesignTokens

/// A content view that paints its window's one backdrop (material, tint,
/// window opacity and blur: `WindowBackdrop`): ``WindowSurfaceView`` and
/// the main window's root. It repaints on its own theme changes;
/// ``NSWindow/install(kind:content:scope:activeLook:)`` calls it once before the
/// content view is installed.
public protocol WindowSurfacePainting: NSView {
    /// The window's one material and tint.
    var backdropView: WindowMaterialView { get }
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
    /// window.install(kind: .settings, content: hostingView, scope: scope, activeLook: services.activeLook)
    /// ```
    ///
    /// `activeLook` is the app's one ``ActiveLookScope`` (its composition root makes it and its
    /// owners pass it down; a child window passes its owner's ``backdropActiveLook``): the window's
    /// backdrop glass keeps its key look while the window is not key. Nil follows the key state. A
    /// kind whose content paints its own backdrop (`.main`) ignores it.
    public func install(kind: WindowKind, content: NSView, scope: ThemeScope, activeLook: ActiveLookScope?) {
        WindowKindRegistry.setKind(kind, of: self)
        let traits = kind.traits
        styleMask.formUnion([.titled, .closable])
        if traits.hidesMinimizeAndZoom {
            standardWindowButton(.miniaturizeButton)?.isHidden = true
            standardWindowButton(.zoomButton)?.isHidden = true
        }
        scope.adopt(self)
        let root: NSView = traits.surface == .backdrop ? WindowSurfaceView(content: content, activeLook: activeLook) : content
        (root as? any WindowSurfacePainting)?.paintWindowSurface(of: self)
        contentView = root
    }

    /// The ``ActiveLookScope`` this window's backdrop was given, for a child window (DevTools, page
    /// info) to pass to its own `install`; nil when the window paints no window-kit backdrop.
    public var backdropActiveLook: ActiveLookScope? { (contentView as? any WindowSurfacePainting)?.backdropView.activeLook }
}

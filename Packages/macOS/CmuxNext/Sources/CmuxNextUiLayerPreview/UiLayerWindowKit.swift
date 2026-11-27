#if CMUX_UI_LAYER_PREVIEW
public import AppKit
import CmuxNextDesign

extension NSWindow {
    /// Gives a UI-host window its content the way every app window gets it (the window kit's
    /// `install`): the app theme scope, its one backdrop (theme tint, material, window opacity
    /// and the person's picture) under `content`, and a titlebar that disappears into it. The
    /// window drags by its background.
    public func installUiLayerContent(_ content: NSView) {
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        styleMask.insert(.fullSizeContentView)
        isMovableByWindowBackground = true
        install(kind: .debugSettings, content: content, scope: .app, activeLook: nil)
    }

    /// Moves the window to `frame` through the panes motion gate, at once when animation is off.
    public func setUiLayerFrame(_ frame: NSRect) {
        Motion.panes.animateTimed(.move, in: contentView) { animator().setFrame(frame, display: true) }
    }
}

extension UiLayerAppLook {
    /// Gives the app scope, the one every real view reads, this look.
    @MainActor public func applyToApp() { apply(to: .app) }
}
#endif

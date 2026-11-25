public import AppKit

extension NSWindow {
    /// Hides the light line AppKit's titlebar decoration draws along the window's top edge, so the
    /// top edge reads like the other three.
    ///
    /// On macOS 26 the decoration (`_NSTitlebarDecorationView`, a CoreUI frame layer as tall as the
    /// titlebar) paints a one-pixel white line at about 10% across the top, in light and dark; macOS
    /// 27 paints none there, and hiding it changes nothing (the glass's own edge highlight is the
    /// line there: ``WindowMaterialView/fillsWindow``). The window's
    /// own rim already runs around all four sides, so where content runs under a transparent
    /// titlebar the top showed a second, brighter line (the user, 2026-11-19: "weird white border at
    /// top of window"). A window with a visible titlebar keeps it: there the line is part of the
    /// titlebar's own look. AppKit keeps the hidden state through style mask, appearance, key and
    /// toolbar changes; ``install(kind:content:scope:activeLook:)`` calls this for every window.
    public func hideTitlebarTopEdgeLine() {
        guard titlebarAppearsTransparent, styleMask.contains(.fullSizeContentView),
              let decoration = NSClassFromString("_NSTitlebarDecorationView"),
              let frame = contentView?.superview else { return }
        for container in frame.subviews where container.className == "NSTitlebarContainerView" {
            for view in container.subviews where view.isKind(of: decoration) && !view.isHidden {
                view.isHidden = true
            }
        }
    }
}

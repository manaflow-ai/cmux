public import QuartzCore

/// A chrome fill the render server paints: a rounded rect, an oval or a ring as layer properties
/// (`backgroundColor`, `cornerRadius`, `borderWidth`, `borderColor`), never a `draw(_:)` backing store.
///
/// Chromium paints solid fills and borders as layer properties, not recorded drawing
/// (cc/layers/solid_color_layer.h, ui/compositor/layer.h `SetColor`), and changes them with Core
/// Animation actions off (ui/base/cocoa/animation_utils.h, `ScopedCAActionDisabler`). This layer has
/// no action for any key: a frame, color, radius or visibility change lands in the frame it is made.
/// A view that owns these sets their colors in `updateLayer` (`wantsUpdateLayer`,
/// `layerContentsRedrawPolicy = .onSetNeedsDisplay`), so a selection move repaints no pixels.
nonisolated public final class ChromeFillLayer: CALayer {
    /// No implicit animation for any key (not even `onOrderIn` and `onOrderOut`).
    override public func action(forKey event: String) -> (any CAAction)? { nil }
}

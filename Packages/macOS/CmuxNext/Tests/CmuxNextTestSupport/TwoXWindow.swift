public import AppKit

/// A window that reports a 2x backing scale whatever display it opens on. The geometry tests that measure drawn pixels at 2x
/// (the omnibar's glyph and capital centering) lay the chrome out on the window's pixel grid, which a headless fleet runner's
/// 1x display rounds to whole points, so a half-point offset measures as a failure there.
public final class TwoXWindow: NSWindow {
    override public var backingScaleFactor: CGFloat { 2 }
}

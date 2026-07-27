public import AppKit

/// `CGSDefaultConnectionForThread`: the per-thread CoreGraphics window-server
/// connection. C runtime trampoline (no Swift declaration exists), so it is one
/// of the sanctioned `@_silgen_name` exceptions to the no-free-function rule.
@_silgen_name("CGSDefaultConnectionForThread")
private func cmuxCGSDefaultConnectionForThread() -> UnsafeMutableRawPointer?

/// `CGSSetWindowBackgroundBlurRadius`: sets the compositor blur radius for a
/// window by window number. C runtime trampoline, sanctioned `@_silgen_name`.
@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
private func cmuxCGSSetWindowBackgroundBlurRadius(
    _ connection: UnsafeMutableRawPointer?,
    _ windowNumber: UInt,
    _ radius: Int32
) -> Int32

/// Wraps the private CoreGraphics window-server shims that drive a window's
/// compositor background blur.
///
/// Lifted faithfully from the `cmuxResetCompositorBackgroundBlur` free function
/// and its two `@_silgen_name` C trampolines in the terminal god file. The
/// controller only resets the blur (radius 0); applying a non-zero blur stays
/// with the app's Ghostty engine path.
///
/// Not actor-isolated: the CGS shims are thread-agnostic C trampolines and this
/// controller takes the already-resolved `windowNumber` value rather than an
/// `NSWindow`, so the main-actor-isolated `NSWindow.windowNumber` read stays in
/// the caller's isolation domain (the legacy `cmuxResetCompositorBackgroundBlur`
/// ran in that same domain).
public struct CompositorBlurController: Sendable {
    /// Creates a compositor-blur controller.
    public init() {}

    /// Resets the compositor background blur on the window with the given
    /// `windowNumber` to zero, matching the legacy
    /// `cmuxResetCompositorBackgroundBlur(on:)`. The caller resolves
    /// `window.windowNumber` in its own (main-actor) isolation domain.
    public func resetBackgroundBlur(windowNumber: Int) {
        _ = cmuxCGSSetWindowBackgroundBlurRadius(
            cmuxCGSDefaultConnectionForThread(),
            UInt(windowNumber),
            0
        )
    }
}

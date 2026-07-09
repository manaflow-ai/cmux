public import GhosttyKit

/// The engine-side compositor blur application for a transparent window.
///
/// `ghostty_set_window_background_blur` reads `background-blur` and
/// `background-opacity` from the app config internally and calls
/// `CGSSetWindowBackgroundBlurRadius`, a compositor-level setter that is
/// idempotent. It is a no-op when opacity >= 1.0 or blur is disabled, so it can
/// be called unconditionally whenever the window is transparent.
///
/// Lifted faithfully from `GhosttyApp.applyWindowBlurIfNeeded(_:)` in the
/// terminal god file. The reset path (blur radius 0) lives in
/// `CmuxWorkspaces.CompositorBlurController`; this is its non-zero counterpart,
/// which must stay on the engine side because it needs the live
/// `ghostty_app_t`. The caller resolves `Unmanaged.passUnretained(window)
/// .toOpaque()` in its own (main-actor) isolation domain and passes the opaque
/// window pointer, exactly as `CompositorBlurController` takes a resolved
/// `windowNumber` rather than an `NSWindow`.
// lint:allow namespace-type — stateless engine FFI wrapper over ghostty C
// values; there is nothing to instantiate and no Swift receiver type to extend.
public struct GhosttyWindowBlurInterop {
    private init() {}

    /// Applies Ghostty's compositor background blur to the given window.
    ///
    /// Mirrors `ghostty_set_window_background_blur(app, windowPointer)` from the
    /// GhosttyKit header. The runtime ignores the call when blur is disabled or
    /// the window is opaque, so the caller may invoke it unconditionally for any
    /// transparent window.
    ///
    /// - Parameters:
    ///   - app: The live runtime app handle. Passing a freed handle is
    ///     undefined behavior, exactly as with any other ghostty C call.
    ///   - windowPointer: The opaque `NSWindow` pointer the runtime reads, as
    ///     produced by `Unmanaged.passUnretained(window).toOpaque()`.
    public static func applyWindowBackgroundBlur(
        app: ghostty_app_t,
        windowPointer: UnsafeMutableRawPointer
    ) {
        ghostty_set_window_background_blur(app, windowPointer)
    }
}

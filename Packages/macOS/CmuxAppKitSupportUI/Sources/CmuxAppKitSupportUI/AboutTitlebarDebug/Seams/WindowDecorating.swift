#if canImport(AppKit)

public import AppKit

/// Applies the app's standard window chrome (background, blur, traffic-light
/// placement, and related decorations) to a freshly built or reconfigured
/// `NSWindow`.
///
/// This inverts the `AboutTitlebarDebug*` types' previous reach into
/// `AppDelegate.shared`: the app target's `AppDelegate` conforms and is injected
/// into ``DebugWindowsCoordinator`` at the composition root, so this package owns
/// no reference to the application delegate.
@MainActor
public protocol WindowDecorating: AnyObject {
    /// Applies the standard cmux window decorations to `window`.
    ///
    /// - Parameter window: The window whose chrome should be normalized.
    func applyWindowDecorations(to window: NSWindow)
}

#endif

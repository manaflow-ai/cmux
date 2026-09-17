public import AppKit

/// Seam the app-target `NSApplication` accessibility swizzle forwards to so it
/// can reuse a cached window-hierarchy snapshot across repeated AX polls.
///
/// A lower package cannot extend `NSApplication`, so the swizzle stays in the
/// executable target and forwards to this seam. The production conformer is
/// ``AccessibilityWindowCache``.
public protocol AccessibilityWindowCaching: AnyObject {
    /// Answers `attribute` for `application` from the cache when the attribute
    /// is one this cache owns, rebuilding the snapshot only when the window
    /// state token changed. Returns ``AccessibilityWindowResolution/passthrough``
    /// for any attribute the cache does not handle, leaving AppKit
    /// authoritative.
    ///
    /// `@MainActor` because it reads main-actor-isolated `NSApplication` /
    /// `NSWindow` state; the app-target swizzle only calls it after a
    /// `Thread.isMainThread` guard.
    @MainActor
    func resolve(
        attribute: NSAccessibility.Attribute,
        application: NSApplication
    ) -> AccessibilityWindowResolution
}

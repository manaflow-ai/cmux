public import AppKit

/// Seam for applying and inspecting the window glass hierarchy.
@MainActor
public protocol WindowGlassEffectManaging: AnyObject {
    /// Identifier assigned to the glass background view.
    var backgroundViewIdentifier: NSUserInterfaceItemIdentifier { get }

    /// Whether native `NSGlassEffectView` is available on this runtime.
    var isAvailable: Bool { get }

    /// Applies the glass hierarchy to a window.
    @discardableResult
    func apply(
        to window: NSWindow,
        tintColor: NSColor?,
        style: WindowGlassEffectStyle?
    ) -> Bool

    /// Updates the tint on the current glass hierarchy.
    func updateTint(to window: NSWindow, color: NSColor?)

    /// Removes the current glass hierarchy from a window.
    @discardableResult
    func remove(from window: NSWindow) -> Bool

    /// Returns the foreground container created above the glass background.
    func foregroundContainer(for window: NSWindow) -> NSView?

    /// Returns the original window content view preserved by the glass root.
    func originalContentView(for window: NSWindow) -> NSView?

    /// Returns the overlay installation target inside the glass foreground.
    func portalInstallationTarget(for window: NSWindow) -> WindowContentOverlayInstallationTarget?
}

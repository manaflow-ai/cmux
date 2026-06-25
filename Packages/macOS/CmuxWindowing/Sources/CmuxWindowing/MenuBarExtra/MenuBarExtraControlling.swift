/// The narrow control surface a ``MenuBarExtraPresentationCoordinator`` drives on
/// a live menu-bar-extra controller.
///
/// The concrete controller is an app-target `NSObject` that owns the `NSStatusItem`,
/// its menu, and the global-search palette window. None of that AppKit state can move
/// into this package, so the coordinator holds the controller only through this seam:
/// it can show/toggle the global-search palette and remove the controller from the
/// menu bar, which is the entire lifecycle the coordinator orchestrates. The app
/// target conforms its `MenuBarExtraController` to this protocol and builds instances
/// through the ``MenuBarExtraPresentationEffects`` factory.
@MainActor
public protocol MenuBarExtraControlling: AnyObject {
    /// Removes the controller's status item from the system menu bar.
    func removeFromMenuBar()

    /// Toggles the persistent controller's global-search palette.
    ///
    /// - Returns: `true` if the controller handled the toggle (its status button was
    ///   available), `false` if the caller should fall back to a transient controller.
    func togglePersistentGlobalSearchPalette() -> Bool

    /// Toggles a transient controller's global-search palette, installing the given
    /// dismissal handler so the controller tears itself down when the palette closes.
    ///
    /// - Returns: `true` if the toggle was handled, `false` if the controller could
    ///   not present (status button unavailable) and should be discarded.
    func toggleTransientGlobalSearchPalette(onDismiss: @escaping () -> Void) -> Bool

    /// Re-renders the controller's debug-only menu affordances.
    func refreshForDebugControls()
}

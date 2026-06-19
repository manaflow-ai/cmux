public import AppKit

/// The app-target seam the ``FileDropOverlayInstaller`` drives for every
/// operation it cannot perform from inside the package: resolving a window's
/// content-overlay installation target (owned by `CmuxAppKitSupportUI`, a
/// higher package that depends on `CmuxWorkspaces`), and creating, finding,
/// configuring, and publishing the concrete `FileDropOverlayView` (an
/// app-target `NSView` that reaches into the live `TabManager`/`Workspace`).
///
/// The installer owns only the generic AppKit positioning algorithm over a
/// plain `NSView`; everything that names an app-target type or touches the
/// per-window associated-object storage inverts through this protocol. The
/// `tabManager` is the live per-window state, passed opaquely as `AnyObject`
/// so the package never imports the workspace god object; the conformer casts
/// it back. The single implementer is the app target.
@MainActor
public protocol FileDropTarget: AnyObject {
    /// Resolves the container/reference view pair the overlay installs into,
    /// or `nil` when the window's theme frame is not ready
    /// (`AppWindowChromeComposition().contentOverlayTargetResolver`).
    func contentOverlayInstallationTarget(
        for window: NSWindow
    ) -> (container: NSView, reference: NSView)?

    /// Returns the already-installed overlay for the window, preferring the
    /// associated-object record and falling back to a recursive search of the
    /// container. The concrete overlay type and the associated-object key are
    /// app-target concerns, so the lookup lives here.
    func existingOverlayView(on window: NSWindow, in container: NSView) -> NSView?

    /// Creates a fresh overlay sized to `frame`, wires its drop handler to the
    /// given `tabManager` (the focused terminal's `handleDroppedURLs`), and
    /// returns it for the installer to position.
    func makeConfiguredOverlayView(frame: NSRect, tabManager: AnyObject) -> NSView

    /// Rebinds an existing overlay's drop handler to the given `tabManager`.
    func reconfigureOverlayView(_ overlay: NSView, tabManager: AnyObject)

    /// Records the overlay on the window (associated-object publish) so
    /// re-entrant lookups and external readers resolve the in-flight view.
    func publishOverlayView(_ overlay: NSView, on window: NSWindow)
}

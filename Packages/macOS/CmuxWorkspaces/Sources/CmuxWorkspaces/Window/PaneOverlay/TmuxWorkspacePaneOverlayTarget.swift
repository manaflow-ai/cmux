public import AppKit
public import CmuxCore

/// The app-target seam the ``TmuxWorkspacePaneOverlayController`` drives for
/// every operation it cannot perform from inside the package: resolving a
/// window's content-overlay installation target (owned by `CmuxAppKitSupportUI`,
/// a higher package that depends on `CmuxWorkspaces`), constructing the
/// passthrough container and the SwiftUI hosting view (both name types — the
/// shared `PassthroughOverlayContainerView` and the app-target
/// `TmuxWorkspacePaneOverlayView`/`TmuxWorkspacePaneOverlayModel` — that the
/// package may not import), and rebuilding the hosting view's root from a
/// ``CmuxCore/TmuxWorkspacePaneOverlayRenderState``.
///
/// The controller owns only the generic AppKit lifecycle over plain `NSView`s:
/// reparenting into the resolved target, edge-pinned constraints, the
/// show/hide + alpha toggle, and the render-state dedup. Everything that names
/// an app-target or higher-package type inverts through this protocol. The
/// single implementer is the app target, constructed once at the composition
/// root.
@MainActor
public protocol TmuxWorkspacePaneOverlayTarget: AnyObject {
    /// Resolves the container/reference view pair the overlay installs into,
    /// or `nil` when the window's theme frame is not ready
    /// (`AppWindowChromeComposition().contentOverlayTargetResolver`).
    func contentOverlayInstallationTarget(
        for window: NSWindow
    ) -> (container: NSView, reference: NSView)?

    /// Creates the transparent, hit-test-passthrough container view the overlay
    /// hosting view is embedded in. The concrete type
    /// (`PassthroughOverlayContainerView`) and its overlay-container identifier
    /// live in a higher package, so the construction is the app target's.
    func makeOverlayContainerView() -> NSView

    /// Creates the SwiftUI hosting view that renders the tmux pane overlay. The
    /// hosted `TmuxWorkspacePaneOverlayView` and its backing
    /// `TmuxWorkspacePaneOverlayModel` are app-target types, so the hosting view
    /// is constructed (and later updated) on the app side.
    func makeOverlayHostingView() -> NSView

    /// Applies a render state to the hosting view: updates the app-target model
    /// and rebuilds the hosting view's root view from the model's snapshot.
    func applyRenderState(_ state: TmuxWorkspacePaneOverlayRenderState, to hostingView: NSView)

    /// Clears the hosting view back to the empty overlay (no unread rects, no
    /// flash) and resets the app-target model.
    func clearRenderState(on hostingView: NSView)
}

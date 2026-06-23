public import AppKit
public import CoreGraphics
public import GhosttyKit

/// The host seam that feeds live `ghostty_surface_t` geometry, AppKit layer
/// access, and app-target appearance side effects to
/// ``TerminalSurfaceRenderCoordinator``.
///
/// The coordinator owns the surface-sizing + appearance/scrollbar/render
/// coalescing *state and decisions* but performs no Ghostty C calls, holds no
/// AppKit views, and reaches no app-target god types. Every read of the live
/// backing geometry, every Metal-layer mutation, every `ghostty_surface_t`
/// resize/color-scheme call, and every app-coupled background-application
/// effect is routed back to the host (the live `GhosttyNSView`) through this
/// protocol. This keeps the latency-sensitive C-surface reads, NSView coordinate
/// conversion, and app-god background composition app-side while the coalescing,
/// dedup, deferral, and retry logic lives in the package.
///
/// The host is held weakly by the coordinator and all members are `@MainActor`.
///
/// > Latency: this cluster is the resize/appearance path, NOT the per-keystroke
/// > path. `forceRefresh()`, `hitTest()`, keydown/IME, and the per-frame tick
/// > loop deliberately do NOT route through this seam.
@MainActor
public protocol TerminalSurfaceRenderHosting: AnyObject {
    // MARK: Backing geometry

    /// Whether the host currently has a live `ghostty_surface_t`.
    func renderHostHasLiveSurface() -> Bool

    /// The host view's current bounds size.
    func renderHostBoundsSize() -> CGSize

    /// Whether the host is currently attached to a window.
    func renderHostHasWindow() -> Bool

    /// The host window's backing scale factor, or `nil` when not in a window.
    func renderHostWindowBackingScaleFactor() -> CGFloat?

    /// The host backing layer's `contentsScale`, or `nil` when no layer exists.
    func renderHostLayerContentsScale() -> CGFloat?

    /// Whether the host view or its window is in an interactive live resize.
    func renderHostInLiveResize() -> Bool

    // MARK: Metal layer

    /// Applies `contentsScale` and `masksToBounds` to the host backing layer,
    /// inside a disabled-action `CATransaction`.
    ///
    /// - Parameter layerScale: The contents scale to apply.
    /// - Returns: Whether the contents scale changed from its prior value.
    func renderHostApplyLayerScale(_ layerScale: CGFloat) -> Bool

    /// Applies a drawable pixel size to the host's `CAMetalLayer`, if realized.
    ///
    /// - Parameters:
    ///   - drawablePixelSize: The target drawable size in device pixels.
    ///   - lastDrawableSize: The coordinator's cached last applied drawable size.
    /// - Returns: The outcome describing whether the Metal layer was realized,
    ///   whether the drawable changed, and the new cached drawable size.
    func renderHostApplyMetalDrawableSize(
        _ drawablePixelSize: CGSize,
        lastDrawableSize: CGSize
    ) -> TerminalSurfaceMetalDrawableResult

    // MARK: Ghostty surface

    /// Pushes a resolved size to the live `ghostty_surface_t`.
    ///
    /// - Returns: Whether the surface size actually changed.
    @discardableResult
    func renderHostApplyTerminalSurfaceSize(
        width: CGFloat,
        height: CGFloat,
        xScale: CGFloat,
        yScale: CGFloat,
        layerScale: CGFloat,
        backingSize: CGSize
    ) -> Bool

    /// Resolves the runtime color scheme the host would apply for an optional
    /// preference, reading the app's effective terminal color-scheme preference
    /// when none is supplied.
    ///
    /// - Parameter preferredColorScheme: An explicit preference, or `nil` to
    ///   read the app default.
    /// - Returns: The resolved ghostty color scheme.
    func renderHostResolveGhosttyColorScheme(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference?
    ) -> ghostty_color_scheme_e

    /// Applies a resolved color scheme to the live `ghostty_surface_t`.
    ///
    /// - Parameter scheme: The resolved ghostty color scheme.
    func renderHostApplyGhosttyColorScheme(_ scheme: ghostty_color_scheme_e)

    /// Emits the host's color-scheme application debug log line, when enabled.
    ///
    /// - Parameters:
    ///   - scheme: The resolved color scheme.
    ///   - force: Whether the application was forced.
    ///   - applied: Whether the scheme was actually applied (vs deduped out).
    func renderHostLogColorScheme(
        scheme: ghostty_color_scheme_e,
        force: Bool,
        applied: Bool
    )

    // MARK: Appearance / background (app-target coupled)

    /// Applies the surface background fill effects (host layer clear + hosted
    /// view fill + optional debug log), faithfully reproducing the legacy
    /// `applySurfaceBackground()` body that reaches `GhosttyApp`, `Workspace`,
    /// and `TerminalSurfaceBackgroundFillPlan`.
    ///
    /// - Parameters:
    ///   - surfaceBackgroundColor: The coordinator-owned per-surface override.
    ///   - lastLoggedSignature: The coordinator's last logged surface signature.
    /// - Returns: The new last-logged signature (unchanged when not logged).
    func renderHostApplySurfaceBackgroundEffects(
        surfaceBackgroundColor: NSColor?,
        lastLoggedSignature: String?
    ) -> String?

    /// Whether the host should apply the window background for the active
    /// selection, faithfully reproducing the legacy window-active gate.
    func renderHostShouldApplyWindowBackground() -> Bool

    /// Applies the window-root backdrop effects, faithfully reproducing the
    /// legacy `applyWindowBackgroundIfActive()` app-coupled body.
    ///
    /// - Parameters:
    ///   - surfaceBackgroundColor: The coordinator-owned per-surface override.
    ///   - lastLoggedSignature: The coordinator's last logged window signature.
    /// - Returns: The new last-logged signature (unchanged when not logged).
    func renderHostApplyWindowBackgroundEffects(
        surfaceBackgroundColor: NSColor?,
        lastLoggedSignature: String?
    ) -> String?

    // MARK: Drag-resize deferral (app-target coupled)

    /// Whether an interactive geometry resize is active (sidebar/split-divider
    /// drag), which short-circuits the stale-drag-pasteboard deferral.
    func renderHostIsInteractiveGeometryResizeActive() -> Bool

    /// Whether the drag pasteboard currently carries tab-transfer UTIs.
    func renderHostHasTabDragPasteboardTypes() -> Bool

    /// The current `NSApp` event type as an opaque resize-event classification,
    /// so the package never imports AppKit event enums.
    func renderHostCurrentEventIsDragResize() -> Bool

    // MARK: Coalesced delivery side effects

    /// Posts the flushed scrollbar to the host's downstream consumers and runs
    /// the copy-mode viewport-jump cursor sync, faithfully reproducing the
    /// legacy `flushPendingScrollbar()` post body.
    ///
    /// - Parameter scrollbar: The newest coalesced scrollbar snapshot.
    func renderHostDidFlushScrollbar(_ scrollbar: GhosttyScrollbar)

    /// Whether the rendered-frame notification demand is currently active.
    func renderHostIsRenderDemandActive() -> Bool

    /// Posts the host's rendered-frame notification, faithfully reproducing the
    /// legacy `flushRenderedFrameUpdate()` post body.
    func renderHostPostRenderedFrame()

    // MARK: Debug-only size tracing

    /// Emits a surface-size defer/resume debug trace line.
    ///
    /// - Parameter trace: The trace describing the size decision.
    func renderHostTraceSurfaceSize(_ trace: TerminalSurfaceSizeTrace)
}

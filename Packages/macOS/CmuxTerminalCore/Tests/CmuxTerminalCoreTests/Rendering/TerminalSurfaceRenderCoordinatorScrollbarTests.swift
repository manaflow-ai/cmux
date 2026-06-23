import AppKit
import CoreGraphics
import GhosttyKit
import Testing
@testable import CmuxTerminalCore

/// A minimal host that records the flushed-scrollbar post body so the tests can
/// prove `flushPendingScrollbarIfAvailable()` actually drains and applies the
/// pending value, not merely returns a boolean. Every other host requirement is
/// a no-op because these tests exercise only the scrollbar pending-slot seam.
@MainActor
private final class FakeRenderHost: TerminalSurfaceRenderHosting {
    var flushedScrollbars: [GhosttyScrollbar] = []

    func renderHostHasLiveSurface() -> Bool { true }
    func renderHostBoundsSize() -> CGSize { .zero }
    func renderHostHasWindow() -> Bool { false }
    func renderHostWindowBackingScaleFactor() -> CGFloat? { nil }
    func renderHostLayerContentsScale() -> CGFloat? { nil }
    func renderHostInLiveResize() -> Bool { false }
    func renderHostApplyLayerScale(_ layerScale: CGFloat) -> Bool { false }
    func renderHostApplyMetalDrawableSize(
        _ drawablePixelSize: CGSize,
        lastDrawableSize: CGSize
    ) -> TerminalSurfaceMetalDrawableResult {
        TerminalSurfaceMetalDrawableResult(
            metalLayerRealized: false,
            drawableSizeChanged: false,
            newLastDrawableSize: lastDrawableSize
        )
    }

    @discardableResult
    func renderHostApplyTerminalSurfaceSize(
        width: CGFloat,
        height: CGFloat,
        xScale: CGFloat,
        yScale: CGFloat,
        layerScale: CGFloat,
        backingSize: CGSize
    ) -> Bool { false }

    func renderHostResolveGhosttyColorScheme(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference?
    ) -> ghostty_color_scheme_e { GHOSTTY_COLOR_SCHEME_DARK }
    func renderHostApplyGhosttyColorScheme(_ scheme: ghostty_color_scheme_e) {}
    func renderHostLogColorScheme(scheme: ghostty_color_scheme_e, force: Bool, applied: Bool) {}
    func renderHostApplySurfaceBackgroundEffects(
        surfaceBackgroundColor: NSColor?,
        lastLoggedSignature: String?
    ) -> String? { lastLoggedSignature }
    func renderHostShouldApplyWindowBackground() -> Bool { false }
    func renderHostApplyWindowBackgroundEffects(
        surfaceBackgroundColor: NSColor?,
        lastLoggedSignature: String?
    ) -> String? { lastLoggedSignature }
    func renderHostIsInteractiveGeometryResizeActive() -> Bool { false }
    func renderHostHasTabDragPasteboardTypes() -> Bool { false }
    func renderHostCurrentEventIsDragResize() -> Bool { false }

    func renderHostDidFlushScrollbar(_ scrollbar: GhosttyScrollbar) {
        flushedScrollbars.append(scrollbar)
    }

    func renderHostIsRenderDemandActive() -> Bool { false }
    func renderHostPostRenderedFrame() {}
    func renderHostTraceSurfaceSize(_ trace: TerminalSurfaceSizeTrace) {}
}

private func makeScrollbar(offset: UInt64) -> GhosttyScrollbar {
    GhosttyScrollbar(c: ghostty_action_scrollbar_s(total: 1000, offset: offset, len: 24))
}

@MainActor
@Suite("Terminal surface render coordinator scrollbar flush")
struct TerminalSurfaceRenderCoordinatorScrollbarTests {
    private func makeCoordinator() -> (TerminalSurfaceRenderCoordinator, FakeRenderHost) {
        let host = FakeRenderHost()
        let coordinator = TerminalSurfaceRenderCoordinator()
        coordinator.host = host
        return (coordinator, host)
    }

    /// The copy-mode fallback regression: with nothing enqueued, the synchronous
    /// flush must report `false` (so the controller runs its line-delta fallback)
    /// and apply nothing — NOT `true` because some value was applied earlier.
    @Test func flushReportsFalseWhenNothingPending() {
        let (coordinator, host) = makeCoordinator()
        #expect(coordinator.flushPendingScrollbarIfAvailable() == false)
        #expect(host.flushedScrollbars.isEmpty)
        #expect(coordinator.scrollbar == nil)
    }

    /// An un-drained enqueued value is reported and synchronously drained: the
    /// flush returns `true`, applies `scrollbar`, and runs the host post body.
    @Test func flushDrainsPendingValueSynchronously() {
        let (coordinator, host) = makeCoordinator()
        coordinator.enqueueScrollbarUpdate(makeScrollbar(offset: 42))

        #expect(coordinator.flushPendingScrollbarIfAvailable())
        #expect(coordinator.scrollbar?.offset == 42)
        #expect(host.flushedScrollbars.map(\.offset) == [42])

        // The slot is now drained; a second synchronous flush reports false and
        // does not re-run the post body (faithful to the legacy drain semantics).
        #expect(coordinator.flushPendingScrollbarIfAvailable() == false)
        #expect(host.flushedScrollbars.count == 1)
    }

    /// Once a value has been applied, a later flush with no NEW pending value
    /// reports `false` — proving the seam tracks "un-drained pending", not "ever
    /// applied" (the exact semantic the regression conflated).
    @Test func flushReportsFalseAfterPreviousApplyWithNoNewPending() {
        let (coordinator, _) = makeCoordinator()
        coordinator.enqueueScrollbarUpdate(makeScrollbar(offset: 7))
        #expect(coordinator.flushPendingScrollbarIfAvailable())
        #expect(coordinator.scrollbar != nil)

        // A scrollbar value has now been applied. Without a fresh enqueue the
        // pending slot is empty, so the next flush must still be false.
        #expect(coordinator.flushPendingScrollbarIfAvailable() == false)
    }
}

import AppKit
import CmuxTerminalCore
import GhosttyKit
import Testing
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_renderer_realized_begin")
private func beginRendererRealizedTracking(_ surface: UnsafeMutableRawPointer)

@_silgen_name("cmux_test_ghostty_renderer_realized_reset")
private func resetRendererRealizedTracking()

@_silgen_name("cmux_test_ghostty_renderer_realized_call_count")
private func rendererRealizedCallCount() -> UInt32

@_silgen_name("cmux_test_ghostty_renderer_rebuild_call_count")
private func rendererRebuildCallCount() -> UInt32

@_silgen_name("cmux_test_ghostty_renderer_realized_call_value")
private func rendererRealizedCallValue(_ index: UInt32) -> Bool

@_silgen_name("cmux_test_ghostty_renderer_occlusion_visible")
private func rendererOcclusionVisible() -> Bool

@_silgen_name("cmux_test_ghostty_renderer_release_was_occluded")
private func rendererReleaseWasOccluded() -> Bool

/// Window-level occlusion: the visible tab of a miniaturized or fully covered
/// window must occlude the core surface, become reclaimable, and replay its
/// presentation transition when the window returns on screen.
@MainActor
@Suite(.serialized) struct TerminalSurfaceWindowOcclusionTests {
    @Test func windowHideOccludesAndUnprotectsTheRenderer() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        #expect(surface.isRendererPresented)
        #expect(rendererOcclusionVisible())
        #expect(!surface.releaseRenderer())

        surface.setRendererWindowVisible(false)

        #expect(!rendererOcclusionVisible())
        #expect(!surface.isRendererEffectivelyVisible)
        #expect(surface.isRendererPortalVisible)
        #expect(surface.releaseRenderer())
        #expect(rendererRealizedCalls() == [false])
        #expect(rendererReleaseWasOccluded())
    }

    @Test func windowShowReplaysPresentationAfterReclaim() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        surface.setRendererWindowVisible(false)
        #expect(surface.releaseRenderer())
        #expect(!surface.isRendererPresented)

        surface.setRendererWindowVisible(true)

        #expect(surface.isRendererPresented)
        #expect(rendererRebuildCallCount() == 1)
        #expect(rendererOcclusionVisible())
    }

    @Test func windowShowWithoutReclaimJustLiftsOcclusion() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        surface.setRendererWindowVisible(false)
        #expect(!rendererOcclusionVisible())

        surface.setRendererWindowVisible(true)

        #expect(rendererOcclusionVisible())
        #expect(surface.isRendererPresented)
        #expect(rendererRebuildCallCount() == 0)
        #expect(rendererRealizedCallCount() == 0)
    }

    @Test func hiddenWindowDefersFirstPresentationUntilShown() {
        let fixture = PresentedSurfaceFixture(windowVisibleAtCreation: false)
        defer { fixture.tearDown() }
        let surface = fixture.surface

        // A runtime created while the window is hidden normalizes into the
        // released state instead of presenting into an invisible window.
        #expect(!surface.isRendererPresented)
        #expect(rendererRealizedCalls() == [false])
        #expect(!rendererOcclusionVisible())

        surface.setRendererWindowVisible(true)

        #expect(surface.isRendererPresented)
        #expect(rendererRebuildCallCount() == 1)
        #expect(rendererOcclusionVisible())
    }

    @Test func portalRevealInsideHiddenWindowKeepsOcclusion() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        surface.setRendererWindowVisible(false)
        #expect(!rendererOcclusionVisible())

        surface.applyVisibilityOcclusion(true)

        #expect(!rendererOcclusionVisible())
    }

    @Test func hiddenPortalIgnoresWindowTransitions() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        // The portal host applies occlusion alongside the visibility flip.
        surface.setRendererPortalVisible(false)
        surface.applyVisibilityOcclusion(false)
        #expect(!rendererOcclusionVisible())

        surface.setRendererWindowVisible(false)
        surface.setRendererWindowVisible(true)

        // A hidden portal stays occluded regardless of window visibility.
        #expect(!rendererOcclusionVisible())
        #expect(rendererRebuildCallCount() == 0)
    }

    private func rendererRealizedCalls() -> [Bool] {
        (0..<rendererRealizedCallCount()).map(rendererRealizedCallValue)
    }
}

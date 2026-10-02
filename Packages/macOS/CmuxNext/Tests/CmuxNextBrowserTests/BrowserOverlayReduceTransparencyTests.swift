import AppKit
import CmuxNextDesign
@testable import CmuxNextBrowser
import Testing

/// The find bar, prompt bar and page notices are overlay surfaces: under Reduce
/// Transparency (injected, never the system toggle) they draw the opaque
/// theme fill, and they follow the setting live.
@MainActor @Suite struct BrowserOverlayReduceTransparencyTests {
    private func expectFollowsReduceTransparency(_ surface: OverlaySurfaceView?, _ label: String) throws {
        let surface = try #require(surface, "\(label)")
        ReduceTransparency.shared.override = true
        #expect(surface.material == .opaque, "\(label)")
        #expect(!(surface.materialDrawingView is NSGlassEffectView), "\(label)")
        #expect(surface.materialDrawingView?.layer?.backgroundColor?.alpha == 1, "\(label)")
        ReduceTransparency.shared.override = false
        #expect(surface.material == .liquidGlass, "\(label)")
        #expect(surface.materialDrawingView is NSGlassEffectView, "\(label)")
    }

    @Test func theFindBarResolvesThroughTheOverlaySurface() throws {
        defer { ReduceTransparency.shared.override = nil }
        try expectFollowsReduceTransparency(FindBarView(frame: .zero).glass, "find bar")
    }

    @Test func thePromptBarResolvesThroughTheOverlaySurface() throws {
        defer { ReduceTransparency.shared.override = nil }
        try expectFollowsReduceTransparency(PromptBarView(frame: .zero).glass, "prompt bar")
    }

    @Test func theNoticesResolveThroughTheOverlaySurface() throws {
        defer { ReduceTransparency.shared.override = nil }
        try expectFollowsReduceTransparency(BrowserNoticeView(frame: .zero).glass, "notice")
        try expectFollowsReduceTransparency(PageUnresponsiveView(frame: .zero).glass, "page unresponsive")
    }

    /// The legibility veil is for glass over a page; the opaque fill shows
    /// unchanged, and the veil returns with the glass.
    @Test func theVeilDropsUnderReduceTransparency() throws {
        ReduceTransparency.shared.override = false
        defer { ReduceTransparency.shared.override = nil }
        let bar = FindBarView(frame: .zero)
        let surface = try #require(bar.glass)
        let veil = try #require(surface.contentView.subviews.first as? OverlayBackingView)
        veil.updateLayer()
        #expect((veil.layer?.backgroundColor?.alpha ?? 0) > 0.5)
        ReduceTransparency.shared.override = true
        veil.updateLayer()
        #expect(veil.layer?.backgroundColor?.alpha == 0)
        ReduceTransparency.shared.override = false
        veil.updateLayer()
        #expect((veil.layer?.backgroundColor?.alpha ?? 0) > 0.5)
    }

    @Test func barsStartOpaqueUnderReduceTransparency() throws {
        ReduceTransparency.shared.override = true
        defer { ReduceTransparency.shared.override = nil }
        #expect(FindBarView(frame: .zero).glass?.material == .opaque)
        #expect(PromptBarView(frame: .zero).glass?.material == .opaque)
    }
}

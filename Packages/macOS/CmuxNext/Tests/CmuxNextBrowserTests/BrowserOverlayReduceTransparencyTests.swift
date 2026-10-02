import AppKit
import CmuxNextDesign
@testable import CmuxNextBrowser
import Testing

/// The find bar and the prompt bar are overlay surfaces: under Reduce
/// Transparency (injected, never the system toggle) they draw the opaque
/// theme fill, and they follow the setting live.
@MainActor @Suite struct BrowserOverlayReduceTransparencyTests {
    private func expectFollowsReduceTransparency(_ surface: OverlaySurfaceView?, _ label: String) throws {
        let surface = try #require(surface, "\(label)")
        ReduceTransparency.override = true
        #expect(surface.material == .opaque, "\(label)")
        #expect(!(surface.materialDrawingView is NSGlassEffectView), "\(label)")
        #expect(surface.materialDrawingView?.layer?.backgroundColor?.alpha == 1, "\(label)")
        ReduceTransparency.override = false
        #expect(surface.material == .liquidGlass, "\(label)")
        #expect(surface.materialDrawingView is NSGlassEffectView, "\(label)")
    }

    @Test func theFindBarResolvesThroughTheOverlaySurface() throws {
        defer { ReduceTransparency.override = nil }
        try expectFollowsReduceTransparency(FindBarView(frame: .zero).glass, "find bar")
    }

    @Test func thePromptBarResolvesThroughTheOverlaySurface() throws {
        defer { ReduceTransparency.override = nil }
        try expectFollowsReduceTransparency(PromptBarView(frame: .zero).glass, "prompt bar")
    }

    @Test func barsStartOpaqueUnderReduceTransparency() throws {
        ReduceTransparency.override = true
        defer { ReduceTransparency.override = nil }
        #expect(FindBarView(frame: .zero).glass?.material == .opaque)
        #expect(PromptBarView(frame: .zero).glass?.material == .opaque)
    }
}

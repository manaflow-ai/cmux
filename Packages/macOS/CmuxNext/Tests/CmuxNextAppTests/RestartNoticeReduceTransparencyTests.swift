import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// The restart notice is an overlay surface: under Reduce Transparency
/// (injected, never the system toggle) it draws the opaque theme fill and
/// follows the setting live.
@MainActor @Suite struct RestartNoticeReduceTransparencyTests {
    @Test func theNoticeResolvesThroughTheOverlaySurface() throws {
        ReduceTransparency.shared.override = true
        defer { ReduceTransparency.shared.override = nil }
        let notice = RestartNoticePanel(text: "Restarted", onShowLog: nil)
        let surface = try #require(notice.surface)
        #expect(surface.material == .opaque)
        #expect(!(surface.materialDrawingView is NSGlassEffectView))
        #expect(surface.materialDrawingView?.layer?.backgroundColor?.alpha == 1)
        #expect(notice.text == "Restarted")
        ReduceTransparency.shared.override = false
        #expect(surface.material == .liquidGlass)
        #expect(surface.materialDrawingView is NSGlassEffectView)
    }
}

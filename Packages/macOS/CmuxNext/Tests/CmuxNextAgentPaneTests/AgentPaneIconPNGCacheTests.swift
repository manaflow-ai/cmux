@testable import CmuxNextAgentPane
import AppKit
import Foundation
import Testing

/// Reply chips and the "Open in" menu encode each icon once, not on every request (hq#18524, the
/// main-actor pass of docs/reading/2026-11-21-wwdc26-instruments-responsiveness.md in cmuxterm-hq).
@MainActor
struct AgentPaneIconPNGCacheTests {
    private static func image(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
    }

    @Test func faviconEncodesOncePerImage() throws {
        let image = Self.image(.red)
        let first = try #require(AgentPaneReplySite.png(image))
        #expect(AgentPaneReplySite.png(image) == first)
        // A different image is encoded on its own.
        #expect(AgentPaneReplySite.png(Self.image(.green)) != first)
    }

    @Test func browserIconIsReusedForTheSameBundle() {
        let browsers = AgentPaneWorkspaceBrowsers()
        let app = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let first = browsers.iconPNG(of: app)
        #expect(first != nil)
        #expect(AgentPaneWorkspaceBrowsers().iconPNG(of: app) == first)
    }
}

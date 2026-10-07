import AppKit
@testable import CmuxNextHome
import Testing

/// nxdog68-v1: over a light background image the transparent people list was
/// hard to read. Like Messages' sidebar, the list sits on a vibrancy material
/// blended within the window: the image still shows through (blurred), and
/// the labels get a legible base. Never an opaque fill.
@MainActor @Suite struct HomeSidebarLegibilityTests {
    @Test func theListSitsOnAWithinWindowSidebarMaterial() throws {
        let sidebar = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        let material = try #require(sidebar.subviews.first as? NSVisualEffectView, "the material is the bottom view")
        #expect(material.material == .sidebar)
        #expect(material.blendingMode == .withinWindow, "the window's image shows through it")
        #expect(material.frame == sidebar.bounds)
        #expect(sidebar.layer?.backgroundColor == nil && !sidebar.isOpaque, "no opaque fill")
    }
}

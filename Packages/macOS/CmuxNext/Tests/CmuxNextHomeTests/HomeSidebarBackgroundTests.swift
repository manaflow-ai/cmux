import AppKit
@testable import CmuxNextHome
import Testing

/// Lawrence (nxdog63-v2): "people area needs transparent bg"; nxdog68-v1:
/// over a light background image the transparent list was hard to read.
/// The Home list column lays one translucent scrim of the window's own
/// background over the backdrop: the image still shows through, the labels
/// get a calmer base. No vibrancy material (it rendered as a solid gray
/// panel) and no opaque fill.
@MainActor @Suite struct HomeSidebarBackgroundTests {
    @Test func theListColumnHasATranslucentScrimAndNoMaterial() throws {
        let sidebar = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        sidebar.layoutSubtreeIfNeeded()
        #expect(!sidebar.isOpaque)
        #expect(!Self.subtree(of: sidebar).contains { $0 is NSVisualEffectView }, "no vibrancy material under the list")
        let scrim = try #require(sidebar.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)), "the column lays a scrim")
        #expect(scrim.alphaComponent > 0, "the scrim is visible")
        #expect(scrim.alphaComponent < 1, "the window's image shows through the scrim")
        for view in Self.subtree(of: sidebar).dropFirst() {
            #expect(view.layer?.backgroundColor == nil, "\(type(of: view)) fills over the scrim")
        }
    }

    /// `view` and every view under it.
    private static func subtree(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(subtree(of:))
    }
}

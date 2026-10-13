import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// cx-y2uf5 (2): a drag in the band above the list that changes the band's height (its preview
/// takes a section out) springs the band's rows, but the band itself and the list under it took
/// their new size at once, a frame ahead of the rows. They now move with the rows.
@MainActor @Suite(.serialized) struct SidebarBandResizeMotionTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// The geometry animations on `layer` itself (not a fade's opacity).
    private static func moved(_ layer: CALayer?) -> [String] {
        (layer?.animationKeys() ?? []).filter { key in
            let path = (layer?.animation(forKey: key) as? CAPropertyAnimation)?.keyPath ?? key
            return path.hasPrefix("position") || path.hasPrefix("bounds") || path.hasPrefix("frame")
        }
    }

    /// The band animates in a window on screen: with no screen Motion snaps it.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func theBandAboveTheListResizesWithItsRows() throws {
        let top = SidebarLayoutDocument.defaults.sections[0]
        let more = LayoutSection(id: LayoutSectionID("sec_more"), region: .top, look: .builtIn, items: [
            LayoutItem(id: LayoutItemID("itm_settings"), ref: .builtIn(.settings)),
            LayoutItem(id: LayoutItemID("itm_history"), ref: .builtIn(.history)),
            LayoutItem(id: LayoutItemID("itm_bookmarks"), ref: .builtIn(.bookmarks)),
        ])
        let model = SidebarModel()
        model.layout = SidebarLayoutDocument(sections: [top, more] + SidebarLayoutDocument.defaults.sections.dropFirst())
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        sidebar.layoutSubtreeIfNeeded()
        let region = sidebar.aboveRegion
        let before = sidebar.aboveFade.frame.height
        try #require(region.layoutResult.height > 0, "the band above the list drew nothing")

        // Synchronous from here to the reset: the override is process-wide.
        let (band, mask) = try { () throws -> ([String], [String]) in
            Motion.reduceMotionOverride = false
            defer { Motion.reduceMotionOverride = nil }
            try #require(Motion.animatesMovement, "animation speed is off on this host")
            // A drag's preview takes the second section out: the band gets shorter.
            region.reorderSections = [top]
            region.relayout(animated: true)
            sidebar.layoutSubtreeIfNeeded()
            return (Self.moved(sidebar.aboveFade.layer), Self.moved(sidebar.aboveFade.layer?.mask))
        }()
        try #require(sidebar.aboveFade.frame.height < before, "the band kept its height")
        #expect(!band.isEmpty, "the band took its new height at once, ahead of its rows")
        // Its edge fade's mask follows its bounds, or the band's rows clip early.
        #expect(!mask.isEmpty, "the band's fade mask took its new size at once")
    }
}

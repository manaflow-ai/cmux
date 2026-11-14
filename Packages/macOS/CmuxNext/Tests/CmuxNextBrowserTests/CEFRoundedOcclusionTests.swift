import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// Lawrence 2026-10-27 ("dialog sides has weird bg"): a Chromium page is a child window above the
/// chrome, so the save-password and find bars punch a hole in it. A square hole showed the pane
/// ground in the four corners outside the bars' rounded glass. The bars now leave the page's clip
/// shape as rounded holes: the page shows (and takes the mouse) around their corners, and the
/// bar shows (and takes the mouse) inside them.
@MainActor @Suite struct CEFRoundedOcclusionTests {
    static let page = CGRect(x: 0, y: 0, width: 800, height: 600)
    static let bar = CEFClipShape.RoundedRect(rect: CGRect(x: 100, y: 500, width: 600, height: 80), radius: 16)

    @Test func aRoundedBarLeavesThePageWithItsCorners() throws {
        let shape = try #require(CEFClipShape.path(bounds: Self.page, clips: [], roundedHoles: [Self.bar]))
        #expect(!shape.contains(CGPoint(x: 400, y: 540)), "the bar's middle is a hole in the page")
        #expect(!shape.contains(CGPoint(x: 101, y: 540)), "the bar's straight left edge is a hole")
        #expect(shape.contains(CGPoint(x: 101, y: 501)), "the page shows in the bar's bottom-left corner, outside its rounding")
        #expect(shape.contains(CGPoint(x: 699, y: 579)), "the page shows in the bar's top-right corner, outside its rounding")
        #expect(shape.contains(CGPoint(x: 400, y: 300)), "the page shows away from the bar")
    }

    @Test func aRoundedHoleChangesTheHostGeometry() {
        let host = CEFHostView(frame: Self.page)
        let before = CEFHostGeometry(of: host)
        host.roundedOcclusions = [Self.bar]
        let after = CEFHostGeometry(of: host)
        #expect(before != after, "the fork re-reads the clip when a bar appears")
        #expect(after.clip.path != nil)
    }

    @Test func aBarOutsideThePageAddsNoShape() {
        let away = CEFClipShape.RoundedRect(rect: CGRect(x: 900, y: 0, width: 50, height: 50), radius: 8)
        #expect(CEFClipShape.path(bounds: Self.page, clips: [], roundedHoles: [away]) == nil)
    }

    @Test func aPageCardClipsItsOwnFillInChromium() throws {
        let root = NSView(frame: Self.page)
        let area = PaneContentAreaView(frame: Self.page)
        let host = CEFHostView(frame: Self.page)
        root.addSubview(area)
        area.addSubview(host)
        let before = CEFHostGeometry(of: host)
        area.setChromeClip(card: Self.page, radius: 12, in: root)
        let clipped = CEFHostGeometry(of: host)
        #expect(clipped != before)
        let path = try #require(clipped.clip.path)
        #expect(!path.contains(CGPoint(x: 0.5, y: Self.page.maxY - 0.5)))
        #expect(!path.contains(CGPoint(x: Self.page.maxX - 0.5, y: Self.page.maxY - 0.5)))
        #expect(path.contains(CGPoint(x: Self.page.midX, y: Self.page.maxY - 0.5)))
        area.setChromeClip(card: nil, radius: 0, in: root)
        #expect(CEFHostGeometry(of: host) == before)
    }

    @Test func aCardClipUpdatesOnlyItsOwnChromiumHosts() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: Self.page, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: Self.page)
        let areas = [PaneContentAreaView(frame: Self.page), PaneContentAreaView(frame: Self.page)]
        for area in areas {
            area.addSubview(CEFHostView(frame: Self.page))
            root.addSubview(area)
        }
        window.contentView = root
        let before = CEFHostView.trackerStats.geometryBuilds
        areas[0].setChromeClip(card: Self.page, radius: 12, in: root)
        #expect(CEFHostView.trackerStats.geometryBuilds == before + 1,
                "a clip change must not rebuild geometry for the other area's page")
    }
}

import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// Stills of the Chief's sidebar rows for Lawrence 2026-11-23 (msg 48175, "get rid of the crown"), dark and light:
/// the top row (the Home item, which is the Chief) and the Chief Activity item, with no Chief picture, so the glyph
/// shows. Written under `chief-row-gallery/` and bundled to `chief-row-gallery.tar` for `cmux-ci run --artifact`, so a
/// run before the change and one after compare.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAChiefRowGalleryTests {
    static let homeItem = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)
    static let chiefItem = LayoutItem(id: LayoutItemID("itm_chief_activity"), ref: .builtIn(.chief))

    static func list() -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list,
                                items: [homeItem, chiefItem])
        let infos = SidebarBridge.itemInfo(for: SidebarLayoutDocument(sections: [top]), registered: { _ in true })
        let model = SidebarModel(sections: [SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: [])])
        let list = SidebarListView(model: model)
        var metrics = SidebarRegionMetrics.standard
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        list.blocks = SidebarListBlocks(sections: [top.id.rawValue: top], infos: infos, collapsed: [], look: .quiet,
                                        metrics: metrics, drawsLines: false, appHeights: [:])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 90), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 90))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        for region in list.blockRegions { region.itemViews.values.forEach { $0.needsLayout = true; $0.layoutSubtreeIfNeeded() } }
        return (list, window)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "chief-row-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            let (_, window) = Self.list()
            defer { window.close() }
            try AADragStartGalleryTests.theme(window, dark: dark)
            try AAGroupHeaderDensityGalleryTests.write(AADragStartGalleryTests.shot(window),
                                                       to: out.appending(path: "chief-rows-\(dark ? "dark" : "light").png"))
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "chief-row-gallery.tar", "chief-row-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

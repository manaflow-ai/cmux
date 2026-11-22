import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Crops for Lawrence default "a site with no favicon gets a placeholder (a neutral globe glyph in the same icon slot)":
/// a site with a favicon and a site without one, mapped from daemon workspaces (`SidebarMapping.row`) and drawn by the
/// real list at every density and text size, dark and light; and the no-favicon site on the other favicon surfaces
/// (the hover card's tab row, a band list row and a band tile). Written under `favicon-placeholder-gallery/` as
/// `<density>-<textSize>-<dark|light>.png`, `rows.png` (one row per density and text size, dark left, light right),
/// `surfaces-<dark|light>.png` and `surfaces.png`, bundled to `favicon-placeholder-gallery.tar` for
/// `cmux-ci run --artifact`, so a run before the fix and one after compare.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAFaviconPlaceholderGalleryTests {
    static let width: CGFloat = 240

    static func rows() throws -> [SidebarWorkspace] {
        [try SidebarFaviconPlaceholderTests.row(id: 1, url: "https://github.com/manaflow-ai/cmux", hasFavicon: true),
         try SidebarFaviconPlaceholderTests.row(id: 2, url: "https://example.com/docs", hasFavicon: false)]
    }

    static func crop(density: SidebarDensity, textSize: SidebarTextSize, dark: Bool) throws -> CGImage {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        var shot: CGImage?
        try SidebarGroupRailAlignmentTests.with(density, .off, textSize: textSize) {
            let rows = try rows()
            let (list, window) = SidebarFaviconPlaceholderTests.list(rows)
            defer { window.close() }
            let root = try #require(window.contentView)
            try AAPinnedNoCloseGalleryTests.theme(root, window, dark: dark)
            root.layer?.backgroundColor = root.performWithTheme { Palette.sidebarBackground.withAlphaComponent(1) }.cgColor
            PointerHover.setDebugPointer(nil, in: window)
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()
            list.rowViews.values.forEach { $0.needsLayout = true; $0.layoutSubtreeIfNeeded() }
            let first = try HomePinnedRowAlignmentTests.row(list, rows[0].id), last = try HomePinnedRowAlignmentTests.row(list, rows[1].id)
            var area = root.convert(first.bounds, from: first).union(root.convert(last.bounds, from: last))
            area.origin.x = 0
            area.size.width = width
            shot = try AAPinnedNoCloseGalleryTests.crop(root, area)
        }
        return try #require(shot)
    }

    /// The no-favicon site on the hover card's tab row (its mapped tab, with a favicon tab above for reference), then as
    /// a band list row and a band tile (`SidebarWorkspaceItems.workspaceInfo`), beside a favicon item.
    static func surfacesCrop(dark: Bool) throws -> CGImage {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let rowHeight: CGFloat = 30, tileSide: CGFloat = 64
        let height = rowHeight * 4 + tileSide + 16
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = root
        try AAPinnedNoCloseGalleryTests.theme(root, window, dark: dark)
        root.layer?.backgroundColor = root.performWithTheme { Palette.sidebarBackground.withAlphaComponent(1) }.cgColor
        let card = NSView(frame: NSRect(x: 0, y: height - rowHeight * 2, width: width, height: rowHeight * 2))
        card.wantsLayer = true
        card.layer?.backgroundColor = root.performWithTheme { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        root.addSubview(card)
        let rows = try rows()
        for (index, row) in rows.enumerated() {
            let tab = try #require(row.tabs.first)
            let view = WorkspaceTabHoverCardRow(style: .standard)
            view.frame = NSRect(x: 4, y: rowHeight * CGFloat(1 - index), width: width - 8, height: rowHeight)
            card.addSubview(view)
            view.configure(tab, now: Date())
            view.applyColors()
        }
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, kind: .browser, title: "Page", url: "https://example.com/docs")])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 2, key: nil, name: "workspace-page",
                                                                        screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])])]))
        let workspace = try #require(store.workspaces.first)
        var withFavicon = SidebarItemInfo(title: "github.com", symbol: "globe")
        withFavicon.favicon = SidebarFaviconPlaceholderTests.favicon
        let infos = [withFavicon, SidebarWorkspaceItems.workspaceInfo(workspace, machine: .local)]
        for (index, info) in infos.enumerated() {
            let item = SidebarItemRowView(frame: NSRect(x: 0, y: height - rowHeight * CGFloat(3 + index), width: width, height: rowHeight))
            root.addSubview(item)
            item.configure(info, style: .list)
            let tile = SidebarItemRowView(frame: NSRect(x: 8 + CGFloat(index) * (tileSide + 4), y: 8, width: tileSide, height: tileSide))
            root.addSubview(tile)
            tile.configure(info, style: .favorite)
        }
        PointerHover.setDebugPointer(nil, in: window)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return try AAPinnedNoCloseGalleryTests.crop(root, root.bounds)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "favicon-placeholder-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var rows: [[CGImage]] = []
        for density in SidebarDensity.allCases {
            for textSize in SidebarTextSize.allCases {
                var row: [CGImage] = []
                for dark in [true, false] {
                    let image = try Self.crop(density: density, textSize: textSize, dark: dark)
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(
                        path: "\(density.rawValue)-\(textSize.rawValue)-\(dark ? "dark" : "light").png"))
                    row.append(image)
                }
                rows.append(row)
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try AAFaviconStyleGalleryTests.sheet(rows), to: out.appending(path: "rows.png"))
        var surfaces: [CGImage] = []
        for dark in [true, false] {
            let image = try Self.surfacesCrop(dark: dark)
            try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "surfaces-\(dark ? "dark" : "light").png"))
            surfaces.append(image)
        }
        try AAGroupHeaderDensityGalleryTests.write(try AAFaviconStyleGalleryTests.sheet([surfaces]), to: out.appending(path: "surfaces.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "favicon-placeholder-gallery.tar", "favicon-placeholder-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

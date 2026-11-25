import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Crops for Lawrence msg 19869 ("also see if we can make these favicons look better"): workspace rows with a GitHub-like
/// dark mono favicon, a white mono favicon, a colourful favicon and no favicon, in every `sidebar.faviconStyle`, at each
/// density, dark and light; and the same favicons on the other surfaces that draw them through the one favicon path
/// (`SidebarFaviconRenditions`): the workspace hover card's tab rows and the band items (a list row and a favorite tile).
/// Written under `favicon-style-gallery/` as `<style>-<density>-<dark|light>.png` and `<style>-surfaces-<dark|light>.png`,
/// with `<density>.png` and `surfaces.png` (styles top to bottom, dark left and light right) and `before-after.png`
/// (`current` then `adaptive`, dark then light, one row per density, then the surfaces), bundled to
/// `favicon-style-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAFaviconStyleGalleryTests {
    static let width: CGFloat = 240
    static let ids = ["github", "vercel", "google", "plain"].map { WorkspaceID("ws-favicon-\($0)") }

    /// The rows: GitHub (dark mono), a white mono mark, a colourful mark, and a row without a favicon.
    static func list() -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(SidebarWorkspace(id: ids[0], title: "Chromium 156 test fixes",
                                            icon: .favicon(SidebarFavicon(SidebarFaviconLegibilityTests.monoMark(white: false))))),
                .workspace(SidebarWorkspace(id: ids[1], title: "Deploy preview",
                                            icon: .favicon(SidebarFavicon(SidebarFaviconLegibilityTests.monoMark(white: true))))),
                .workspace(SidebarWorkspace(id: ids[2], title: "Text Chief iMessage",
                                            icon: .favicon(SidebarFavicon(SidebarFaviconLegibilityTests.colourful())))),
                .workspace(SidebarWorkspace(id: ids[3], title: "Sidebar fixes a590")),
            ]),
        ])
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        return (list, window)
    }

    /// The three favicons (dark mono, white mono, colourful) and none, with their row titles.
    static var favicons: [(String, SidebarFavicon?)] {
        [("Chromium 156 test fixes", SidebarFavicon(SidebarFaviconLegibilityTests.monoMark(white: false))),
         ("Deploy preview", SidebarFavicon(SidebarFaviconLegibilityTests.monoMark(white: true))),
         ("Text Chief iMessage", SidebarFavicon(SidebarFaviconLegibilityTests.colourful())),
         ("Sidebar fixes a590", nil)]
    }

    /// Sets the favicon style for the rest of the caller's scope (cleared by `clearStyle`).
    static func setStyle(_ style: SidebarFaviconStyle) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarFaviconStyle.tunable.key
        try #require(TunableStore.shared.set(key, style.tunableValue) == style.tunableValue, "the style takes the override")
    }

    static func clearStyle() { TunableStore.shared.set(SidebarFaviconStyle.tunable.key, nil) }

    /// The other favicon surfaces in `style`: the hover card's tab rows (on the window background, as the card's veil),
    /// then band items as list rows and as favorite tiles (on the sidebar).
    static func surfacesCrop(style: SidebarFaviconStyle, dark: Bool) throws -> CGImage {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        try setStyle(style)
        defer { clearStyle() }
        let rowHeight: CGFloat = 30, tileSide: CGFloat = 64
        let height = rowHeight * 8 + tileSide + 16
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = root
        try AAPinnedNoCloseGalleryTests.theme(root, window, dark: dark)
        root.layer?.backgroundColor = root.performWithTheme { Palette.sidebarBackground.withAlphaComponent(1) }.cgColor
        let card = NSView(frame: NSRect(x: 0, y: height - rowHeight * 4, width: width, height: rowHeight * 4))
        card.wantsLayer = true
        card.layer?.backgroundColor = root.performWithTheme { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        root.addSubview(card)
        for (index, (title, favicon)) in favicons.enumerated() {
            let row = WorkspaceTabHoverCardRow(style: .standard)
            row.frame = NSRect(x: 4, y: rowHeight * CGFloat(3 - index), width: width - 8, height: rowHeight)
            card.addSubview(row)
            row.configure(SidebarTab(id: TabID("tab-favicon-\(index)"), title: title, kind: .browser, favicon: favicon), now: Date())
            row.applyColors()
        }
        for (index, (title, favicon)) in favicons.enumerated() {
            var info = SidebarItemInfo(title: title, symbol: "globe")
            info.favicon = favicon
            let item = SidebarItemRowView(frame: NSRect(x: 0, y: height - rowHeight * CGFloat(5 + index), width: width, height: rowHeight))
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

    static func crop(style: SidebarFaviconStyle, density: SidebarDensity, dark: Bool) throws -> CGImage {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        try setStyle(style)
        defer { clearStyle() }
        var shot: CGImage?
        try SidebarGroupRailAlignmentTests.with(density, .off) {
            let (list, window) = list()
            defer { window.close() }
            let root = try #require(window.contentView)
            try AAPinnedNoCloseGalleryTests.theme(root, window, dark: dark)
            root.layer?.backgroundColor = root.performWithTheme { Palette.sidebarBackground.withAlphaComponent(1) }.cgColor
            PointerHover.setDebugPointer(nil, in: window)
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()
            list.rowViews.values.forEach { $0.needsLayout = true; $0.layoutSubtreeIfNeeded() }
            let first = try HomePinnedRowAlignmentTests.row(list, ids[0]), last = try HomePinnedRowAlignmentTests.row(list, ids[3])
            var area = root.convert(first.bounds, from: first).union(root.convert(last.bounds, from: last))
            area.origin.x = 0
            area.size.width = width
            shot = try AAPinnedNoCloseGalleryTests.crop(root, area)
        }
        return try #require(shot)
    }

    /// `rows` of images on a grey sheet, each cell the largest image's size, 16 px apart.
    static func sheet(_ rows: [[CGImage]]) throws -> CGImage {
        let gap = 16
        let all = rows.flatMap { $0 }
        let cellW = all.map(\.width).max() ?? 1, cellH = all.map(\.height).max() ?? 1
        let columns = rows.map(\.count).max() ?? 1
        let ctx = try #require(CGContext(data: nil, width: columns * cellW + (columns + 1) * gap, height: rows.count * cellH + (rows.count + 1) * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (row, images) in rows.enumerated() {
            for (col, image) in images.enumerated() {
                let x = gap + col * (cellW + gap), y = ctx.height - (row + 1) * (cellH + gap)
                ctx.draw(image, in: CGRect(x: x, y: y + cellH - image.height, width: image.width, height: image.height))
            }
        }
        return try #require(ctx.makeImage())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "favicon-style-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var shots: [String: CGImage] = [:]
        for density in SidebarDensity.allCases {
            var rows: [[CGImage]] = []
            for style in SidebarFaviconStyle.allCases {
                var row: [CGImage] = []
                for dark in [true, false] {
                    let image = try Self.crop(style: style, density: density, dark: dark)
                    let name = "\(style.rawValue)-\(density.rawValue)-\(dark ? "dark" : "light")"
                    shots[name] = image
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name).png"))
                    row.append(image)
                }
                rows.append(row)
            }
            try AAGroupHeaderDensityGalleryTests.write(try Self.sheet(rows), to: out.appending(path: "\(density.rawValue).png"))
        }
        var surfaceRows: [[CGImage]] = []
        for style in SidebarFaviconStyle.allCases {
            var row: [CGImage] = []
            for dark in [true, false] {
                let image = try Self.surfacesCrop(style: style, dark: dark)
                let name = "\(style.rawValue)-surfaces-\(dark ? "dark" : "light")"
                shots[name] = image
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name).png"))
                row.append(image)
            }
            surfaceRows.append(row)
        }
        try AAGroupHeaderDensityGalleryTests.write(try Self.sheet(surfaceRows), to: out.appending(path: "surfaces.png"))
        // Before (current) and after (adaptive), dark then light, one row per density, then the other surfaces.
        let pairs = try (SidebarDensity.allCases.map(\.rawValue) + ["surfaces"]).map { place in
            try ["current-\(place)-dark", "adaptive-\(place)-dark",
                 "current-\(place)-light", "adaptive-\(place)-light"].map { try #require(shots[$0]) }
        }
        try AAGroupHeaderDensityGalleryTests.write(try Self.sheet(pairs), to: out.appending(path: "before-after.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "favicon-style-gallery.tar", "favicon-style-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

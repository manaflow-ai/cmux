import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Stills of the sidebar in every `sidebar.topLeftCluster` look (Leo 2026-11-05: "that search button, that like
/// magnifying glass, it isn't aligned. And the new workspace, like those two things, like they're just not
/// aligned"), light and dark, at each sidebar density, with 8x nearest-neighbor zooms of the top-right header and
/// of the footer's Search, plus `measurements.json`: both buttons' frames and the measured ink of both glyphs
/// (bounding box in backing pixels, and its center x), so the offset between the + and the magnifying glass is
/// read off the pixels, before (`standard`) and after. `CMUX_TEST_REQUIRE_GUI=1`; writes
/// `top-left-cluster-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AATopLeftClusterGalleryTests {
    struct Shot {
        var image: CGImage
        var scale: CGFloat
        var measured: [String: [CGFloat]]
    }

    static func rect(_ r: NSRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }

    /// The ink of whatever is drawn in `frame` (points, top-left origin): every pixel that differs from the frame's
    /// corner pixel (the background there) by more than `threshold` in any channel. Returns [minX, minY, maxX, maxY,
    /// centerX, centerY] in backing pixels of the whole image, or nil when the frame holds no ink.
    static func ink(_ image: CGImage, scale: CGFloat, in frame: NSRect, threshold: Int = 40) -> [CGFloat]? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let bpp = image.bitsPerPixel / 8, row = image.bytesPerRow
        let px = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale).integral
        let x0 = max(0, Int(px.minX)), y0 = max(0, Int(px.minY))
        let x1 = min(image.width, Int(px.maxX)), y1 = min(image.height, Int(px.maxY))
        guard x1 > x0, y1 > y0 else { return nil }
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let o = y * row + x * bpp
            return (Int(bytes[o]), Int(bytes[o + 1]), Int(bytes[o + 2]))
        }
        let bg = pixel(x0, y0)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = pixel(x, y)
                if max(abs(p.0 - bg.0), abs(p.1 - bg.1), abs(p.2 - bg.2)) > threshold {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return [CGFloat(minX), CGFloat(minY), CGFloat(maxX), CGFloat(maxY),
                CGFloat(minX + maxX + 1) / 2, CGFloat(minY + maxY + 1) / 2]
    }

    static func render(_ look: SidebarTopLeftCluster, density: SidebarDensity, dark: Bool) async throws -> Shot {
        _ = NSApplication.shared
        let previousMotion = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = previousMotion }
        let saved = DesignSettings.shared.sidebarSections
        DesignSettings.shared.sidebarSections.density = density
        DesignSettings.shared.sidebarSections.topLeftCluster = look
        defer { DesignSettings.shared.sidebarSections = saved }

        let width: CGFloat = 280, height: CGFloat = 360
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let themeName = dark ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(themeName)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(themeName), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor

        let model = SidebarModel(sections: AASidebarLookGalleryTests.sections())
        model.expanded = density == .expanded
        model.profileAvatar = SidebarAvatar(name: "Lawrence", color: .blue)
        model.profiles = (0..<3).map { SidebarProfile(id: ProfileKey("space\($0)"), name: "Space \($0)") }
        let design = DesignSettings()
        design.sidebarSections.density = density
        design.sidebarSections.topLeftCluster = look
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        for _ in 0..<20 {
            sidebar.renderNow()
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            if sidebar.footerBand.profileControl != nil { break }
            await Task.yield()
        }
        for _ in 0..<2 {
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
        }
        sidebar.setChromeRevealed(true)
        sidebar.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()

        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        let scale = CGFloat(image.width) / width

        var measured: [String: [CGFloat]] = ["backingScale": [scale]]
        // The sidebar is flipped (top-left origin), as the image rows are.
        if !sidebar.newButton.isHidden {
            measured["newButton"] = rect(sidebar.newButton.frame)
            measured["newButtonInk"] = ink(image, scale: scale, in: sidebar.newButton.frame)
        }
        if !sidebar.searchButton.isHidden {
            measured["searchButton"] = rect(sidebar.searchButton.frame)
            measured["searchButtonInk"] = ink(image, scale: scale, in: sidebar.searchButton.frame)
        }
        if let row = sidebar.newWorkspaceRowIfBuilt, !row.isHidden {
            measured["newWorkspaceRow"] = rect(row.frame)
            measured["newWorkspaceRowGlyph"] = rect(sidebar.convert(row.glyph.frame, from: row))
        }
        if let plus = measured["newButtonInk"], let lens = measured["searchButtonInk"] {
            // Center-x offset between the two glyphs' ink, in backing pixels: 0 is one column.
            measured["plusMinusSearchInkCenterX"] = [plus[4] - lens[4]]
            measured["plusMinusSearchBoxCenterX"] = [(sidebar.newButton.frame.midX - sidebar.searchButton.frame.midX) * scale]
            measured["plusMinusSearchInkWidth"] = [(plus[2] - plus[0]) - (lens[2] - lens[0])]
        }
        measured["trailingColumnCenterX"] = [SidebarStyle.trailingColumnCenterX(sidebarWidth: width)]
        measured["listTop"] = [sidebar.edgeFade.frame.minY]
        window.close()
        return Shot(image: image, scale: scale, measured: measured)
    }

    /// `region` (points, top-left origin) of `image`, drawn `zoom` times larger with no smoothing.
    static func zoomed(_ image: CGImage, scale: CGFloat, region: CGRect, zoom: Int) throws -> CGImage {
        let px = CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale, height: region.height * scale).integral
        let crop = try #require(image.cropping(to: px))
        let ctx = try #require(CGContext(data: nil, width: crop.width * zoom, height: crop.height * zoom, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        return try #require(ctx.makeImage())
    }

    /// Every look but `standard` puts the + on Search's column at Search's size; compact keeps `standard`.
    @Test func plusSharesSearchColumnOutsideCompact() async throws {
        _ = NSApplication.shared
        for density in [SidebarDensity.comfortable, .expanded, .compact] {
            for look in SidebarTopLeftCluster.allCases where look == .aligned || look == .headerRow {
                let saved = DesignSettings.shared.sidebarSections
                DesignSettings.shared.sidebarSections.density = density
                defer { DesignSettings.shared.sidebarSections = saved }
                let design = DesignSettings()
                design.sidebarSections.density = density
                design.sidebarSections.topLeftCluster = look
                let sidebar = SidebarView(model: SidebarModel(), design: design)
                sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 480)
                sidebar.layoutSubtreeIfNeeded()
                let search = SidebarFooterBand.searchPlacement(sidebarWidth: 280, side: SidebarFooterBand.searchButtonSide, itemsMaxX: nil)
                if density == .compact {
                    #expect(sidebar.newButton.frame.maxX == 280 - Metrics.space3, "compact keeps today's +")
                } else {
                    #expect(abs(sidebar.newButton.frame.minX - search.x) < 0.5, "\(density) \(look): + on Search's column")
                    #expect(sidebar.newButton.frame.width == SidebarFooterBand.searchButtonSide)
                    #expect(sidebar.newButton.pointSize() == Metrics.iconSize, "+ at Search's glyph size")
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() async throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "top-left-cluster-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var measurements: [String: [String: [CGFloat]]] = [:]
        for density in [SidebarDensity.comfortable, .expanded, .compact] {
            // Compact draws standard whatever the look: two stills prove it.
            let looks: [SidebarTopLeftCluster] = density == .compact ? [.standard, .headerRow] : SidebarTopLeftCluster.allCases
            for look in looks {
                for dark in [false, true] {
                    let shot = try await Self.render(look, density: density, dark: dark)
                    let name = "\(density.rawValue)-\(look.rawValue)-\(dark ? "dark" : "light")"
                    measurements[name] = shot.measured
                    try AAGroupHeaderDensityGalleryTests.write(shot.image, to: out.appending(path: "\(name).png"))
                    let h = CGFloat(shot.image.height) / shot.scale
                    let w = CGFloat(shot.image.width) / shot.scale
                    // The corner group: the header's trailing end and the list's first rows.
                    try AAGroupHeaderDensityGalleryTests.write(
                        try Self.zoomed(shot.image, scale: shot.scale, region: CGRect(x: w - 96, y: 0, width: 96, height: 72), zoom: 8),
                        to: out.appending(path: "\(name)-top-right-8x.png"))
                    try AAGroupHeaderDensityGalleryTests.write(
                        try Self.zoomed(shot.image, scale: shot.scale, region: CGRect(x: 0, y: 0, width: 140, height: 72), zoom: 8),
                        to: out.appending(path: "\(name)-top-left-8x.png"))
                    try AAGroupHeaderDensityGalleryTests.write(
                        try Self.zoomed(shot.image, scale: shot.scale, region: CGRect(x: w - 64, y: h - 48, width: 64, height: 48), zoom: 8),
                        to: out.appending(path: "\(name)-search-8x.png"))
                }
            }
        }
        let json = try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: out.appending(path: "measurements.json"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "top-left-cluster-gallery.tar", "top-left-cluster-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

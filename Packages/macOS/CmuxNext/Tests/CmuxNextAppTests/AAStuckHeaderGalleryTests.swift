import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills of the stuck project header (Leo 2026-11-11: "ohhh it's showing me the topmost project im in... well that's
/// nice but it doesn't look congruent with the regular look"). Each variant is three tiles: the list at rest, scrolled
/// with the header as it drew before (its band and rim raised over the rows), and scrolled as it draws now (a plain
/// heading on the sidebar's own material, the veil). Variants: a group nobody colored (the screenshot's "Leads") dark, a
/// colored group dark, and the uncolored group light. Written under `stuck-header-gallery/` with `all.png`, bundled to
/// `stuck-header-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAStuckHeaderGalleryTests {
    struct Variant {
        var name: String
        var tint: GroupTint
        var dark: Bool
    }

    static let variants = [
        Variant(name: "no-color-dark", tint: .none, dark: true),
        Variant(name: "green-dark", tint: .palette(.green), dark: true),
        Variant(name: "no-color-light", tint: .none, dark: false),
    ]

    static func snapshot(_ bench: SidebarScrollBench) throws -> CGImage {
        let root = bench.sidebar
        // `cacheDisplay` draws subviews in order and ignores the layers' zPosition, which puts the stuck header over its
        // veil on screen: the capture orders them the same way.
        if let stuck = bench.list.stuckHeader, let header = bench.list.rowViews[stuck.key] {
            bench.list.addSubview(bench.list.stuckVeil, positioned: .above, relativeTo: nil)
            bench.list.addSubview(header, positioned: .above, relativeTo: bench.list.stuckVeil)
        }
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    /// At rest, scrolled as before (`isStuck` off), scrolled as now.
    static func render(_ variant: Variant) throws -> [CGImage] {
        _ = NSApplication.shared
        let bench = SidebarScrollBench(count: 40, height: 300, shape: .oneGroup)
        defer { bench.close() }
        bench.window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        var groups = bench.model.sections[0].nodes
        if case var .group(group) = groups[0] { group.tint = variant.tint; groups[0] = .group(group) }
        bench.model.sections[0].nodes = groups
        bench.sidebar.renderNow()
        bench.drawFrame()
        let rest = try snapshot(bench)
        _ = bench.frame(to: 260)
        let header = try #require(bench.list.rowViews[.group(SidebarStickyHeaderTests.group)] as? GroupHeaderRowView)
        #expect(header.isStuck, "the scrolled list sticks the group's header")
        header.isStuck = false
        let before = try snapshot(bench)
        header.isStuck = true
        let after = try snapshot(bench)
        return [rest, before, after]
    }

    @Test func aStuckHeaderDrawsAsAPlainHeadingAndLetsGoAsItsOwnLook() throws {
        let bench = SidebarScrollBench(count: 40, height: 300, shape: .oneGroup)
        defer { bench.close() }
        let header = try #require(bench.list.rowViews[.group(SidebarStickyHeaderTests.group)] as? GroupHeaderRowView)
        #expect(!header.isStuck)
        _ = bench.frame(to: 260)
        #expect(header.isStuck && !bench.list.stuckVeil.isHidden)
        #expect(header.rim.isHidden, "no rim on the stuck header")
        _ = bench.frame(to: 0)
        #expect(!header.isStuck, "back at its own place it draws its own look again")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "stuck-header-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var rows: [[CGImage]] = []
        for variant in Self.variants {
            let tiles = try Self.render(variant)
            for (tile, label) in zip(tiles, ["rest", "before", "after"]) {
                try AAGroupHeaderDensityGalleryTests.write(tile, to: out.appending(path: "\(variant.name)-\(label).png"))
            }
            rows.append(tiles)
        }
        // One row per variant: rest, before, after.
        let w = rows[0][0].width, h = rows[0][0].height, gap = 16
        let ctx = try #require(CGContext(data: nil, width: 3 * w + 2 * gap, height: rows.count * h + (rows.count - 1) * gap, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (r, tiles) in rows.enumerated() {
            for (c, tile) in tiles.enumerated() {
                ctx.draw(tile, in: CGRect(x: c * (w + gap), y: (rows.count - 1 - r) * (h + gap), width: w, height: h))
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "stuck-header-gallery.tar", "stuck-header-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

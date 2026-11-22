import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Crops for Lawrence msg 19643 ("left alignment here is bad"): the sidebar's top as his shot drew it (Home, pinned rows
/// with their pins, text-only rows around a favicon row, emoji rows and a symbol row; `SidebarLeadingEdgeTests.list`) in
/// each `sidebar.leadingColumn` look: `centered` (before: each glyph centered in the icon column), `inset` (after: every
/// glyph's ink at the row inset) and `slotted` (the Chief's alternative: as `inset`, plus an empty icon slot on text-only
/// rows). Dark and light, at compact density, each with a 1 px magenta guide at the row inset and a cyan guide at the
/// icon column's center. Written under `leading-column-gallery/` with `all.png` (dark on top, light below; before,
/// after, slotted left to right), bundled to `leading-column-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AALeadingColumnGalleryTests {
    static let looks: [SidebarLeadingColumnLook] = [.centered, .inset, .slotted]
    static let names = ["before-centered", "after-inset", "variant-slotted"]
    static let width: CGFloat = 220

    /// The top of the sidebar in `look`, themed, with the inset and icon column center guides drawn over it.
    static func crop(look: SidebarLeadingColumnLook, dark: Bool) throws -> CGImage {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarLeadingColumnLook.tunable.key
        defer { TunableStore.shared.set(key, nil) }
        try #require(TunableStore.shared.set(key, look.tunableValue) == look.tunableValue, "the look takes the override")
        var shot: CGImage?
        try SidebarGroupRailAlignmentTests.with(.compact, .off) {
            let (list, window) = SidebarLeadingEdgeTests.list(width: width)
            defer { window.close() }
            let root = try #require(window.contentView)
            try AAPinnedNoCloseGalleryTests.theme(root, window, dark: dark)
            PointerHover.setDebugPointer(nil, in: window)
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()
            list.rowViews.values.forEach { $0.needsLayout = true; $0.layoutSubtreeIfNeeded() }
            for region in list.blockRegions { region.itemViews.values.forEach { $0.needsLayout = true; $0.layoutSubtreeIfNeeded(); $0.layout() } }
            let home = try HomePinnedRowAlignmentTests.item(list, SidebarLeadingEdgeTests.home.id)
            let last = try HomePinnedRowAlignmentTests.row(list, SidebarLeadingEdgeTests.pinning)
            let top = root.convert(home.bounds, from: home), bottom = root.convert(last.bounds, from: last)
            var area = top.union(bottom)
            area.origin.x = 0
            area.size.width = width
            let inset = try SidebarLeadingEdgeTests.inset(list)
            let center = SidebarStyle.iconColumnCenterX(leading: inset)
            let image = try AAPinnedNoCloseGalleryTests.crop(root, area)
            shot = try guides(image, pointWidth: width, xs: [(inset, CGColor(red: 1, green: 0, blue: 1, alpha: 1)),
                                                             (center, CGColor(red: 0, green: 0.8, blue: 1, alpha: 1))])
        }
        return try #require(shot)
    }

    /// `image` (a crop whose left edge is the root's x 0, `pointWidth` points wide) with a 1 px vertical line at each x.
    static func guides(_ image: CGImage, pointWidth: CGFloat, xs: [(CGFloat, CGColor)]) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let scale = CGFloat(image.width) / pointWidth
        for (x, color) in xs {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: (x * scale).rounded(.down), y: 0, width: 1, height: CGFloat(image.height)))
        }
        return try #require(ctx.makeImage())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "leading-column-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var rows: [[CGImage]] = []
        for dark in [true, false] {
            var images: [CGImage] = []
            for (look, name) in zip(Self.looks, Self.names) {
                let image = try Self.crop(look: look, dark: dark)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
                images.append(image)
            }
            rows.append(images)
        }
        // The crops side by side (before, after, slotted), dark on top and light below.
        let gap = 16
        let cellW = rows.flatMap { $0 }.map(\.width).max() ?? 1, cellH = rows.flatMap { $0 }.map(\.height).max() ?? 1
        let columns = Self.looks.count
        let ctx = try #require(CGContext(data: nil, width: columns * cellW + (columns + 1) * gap, height: 2 * cellH + 3 * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (row, images) in rows.enumerated() {
            for (col, image) in images.enumerated() {
                let x = gap + col * (cellW + gap), y = gap + (1 - row) * (cellH + gap)
                ctx.draw(image, in: CGRect(x: x, y: y + cellH - image.height, width: image.width, height: image.height))
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "leading-column-gallery.tar", "leading-column-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

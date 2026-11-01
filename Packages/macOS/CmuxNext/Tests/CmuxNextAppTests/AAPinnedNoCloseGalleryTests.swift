import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Hover crops for Lawrence msg 19392 ("hover on pinned tab should not have close button, should only be able to
/// close in right click"): a hovered pinned row ("cmux Performance Lead" in the Pinned block), a hovered unpinned
/// workspace row, a hovered pinned tab and a hovered unpinned tab, dark and light. Written under
/// `pinned-noclose-gallery/` with `all.png` (dark on top, light below, the four crops side by side), bundled to
/// `pinned-noclose-gallery.tar` for `cmux-ci run --artifact`, so a before and an after run compare.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAPinnedNoCloseGalleryTests {
    /// Applies the gallery theme to `root` in `window`.
    static func theme(_ root: NSView, _ window: NSWindow, dark: Bool) throws {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        root.wantsLayer = true
        root.appearance = window.appearance
        let name = dark ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(name)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(name), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
    }

    /// Draws `root` and returns the part under `rect` (root coordinates), padded by 6 pt.
    static func crop(_ root: NSView, _ rect: NSRect) throws -> CGImage {
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let shot = try #require(rep.cgImage)
        let scale = CGFloat(shot.width) / root.bounds.width
        var r = rect.insetBy(dx: -6, dy: -6).intersection(root.bounds)
        // Image rows run top down; an unflipped root's y runs bottom up.
        if !root.isFlipped { r.origin.y = root.bounds.height - r.maxY }
        let pixels = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale).integral
        return try #require(shot.cropping(to: pixels))
    }

    /// A hovered pinned row and a hovered unpinned row of the sidebar, in that order.
    static func sidebarCrops(dark: Bool) throws -> [CGImage] {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let harness = SidebarHomePinnedDragHarness()
        defer { harness.close() }
        let root = try #require(harness.window.contentView)
        try theme(root, harness.window, dark: dark)
        harness.settle()
        let pinned = try harness.item(SidebarHomePinnedDragHarness.pins[0].id)
        PinnedNoHoverCloseTests.hover(pinned, in: harness)
        let pinnedCrop = try crop(root, root.convert(pinned.bounds, from: pinned))
        PointerHover.setDebugPointer(nil, in: harness.window)
        let id = SidebarHomePinnedDragHarness.loose[0]
        harness.list.setHovered(.workspace(id))
        let row = try #require(harness.list.rowViews[.workspace(id)])
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        let rowCrop = try crop(root, root.convert(row.bounds, from: row))
        return [pinnedCrop, rowCrop]
    }

    /// A hovered pinned tab and a hovered unpinned tab, in that order.
    static func tabCrops(dark: Bool) throws -> [CGImage] {
        var crops: [CGImage] = []
        for id in [PinnedNoHoverCloseTests.StripHarness.pinned, PinnedNoHoverCloseTests.StripHarness.loose] {
            let harness = PinnedNoHoverCloseTests.StripHarness()
            defer { harness.window.closeAfterTest() }
            let root = NSView(frame: harness.window.contentView?.bounds ?? .zero)
            harness.window.contentView = root
            harness.strip.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: TabStripView.preferredHeight)
            root.addSubview(harness.strip)
            try theme(root, harness.window, dark: dark)
            harness.strip.layoutSubtreeIfNeeded()
            try harness.hover(id)
            let cell = try #require(harness.strip.cells[id])
            let frame = root.convert(harness.strip.convert(cell.frame, from: harness.strip.tabsClip), from: harness.strip)
            crops.append(try crop(root, frame))
        }
        return crops
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "pinned-noclose-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let names = ["pinned-row-hover", "unpinned-row-hover", "pinned-tab-hover", "unpinned-tab-hover"]
        var rows: [[CGImage]] = []
        for dark in [true, false] {
            let images = try Self.sidebarCrops(dark: dark) + Self.tabCrops(dark: dark)
            for (image, name) in zip(images, names) {
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
            }
            rows.append(images)
        }
        // The four crops side by side, dark on top and light below, each in a cell as wide as the widest crop.
        let gap = 16
        let cellW = rows.flatMap { $0 }.map(\.width).max() ?? 1, cellH = rows.flatMap { $0 }.map(\.height).max() ?? 1
        let columns = names.count
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
        tar.arguments = ["cf", "pinned-noclose-gallery.tar", "pinned-noclose-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

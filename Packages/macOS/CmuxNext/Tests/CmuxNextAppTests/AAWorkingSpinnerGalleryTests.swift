import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Crops of the working spinner for Lawrence msg 19638 ("we need it to be reverted back to original state"): a
/// working sidebar row, a collapsed loading group header and a working tab, dark and light. Each crop is the whole
/// row or tab plus its spinner blown up 6x (nearest neighbour), at one fixed angle: a still draws the layers' model
/// values, so every spinner sits at its start angle and two runs compare pixel for pixel. Written under
/// `working-spinner-gallery/` with `all.png` (dark on top, light below, the three crops side by side), bundled to
/// `working-spinner-gallery.tar` for `cmux-ci run --artifact`, so a before and an after run compare.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAWorkingSpinnerGalleryTests {
    typealias T = SidebarTrailingColumnTests

    /// `image` with the square of `side` points at its trailing end blown up 6x beside it.
    static func withZoom(_ image: CGImage, spinner: CGRect, scale: CGFloat) throws -> CGImage {
        let pixels = CGRect(x: spinner.minX * scale, y: spinner.minY * scale, width: spinner.width * scale,
                            height: spinner.height * scale).integral
        let part = try #require(image.cropping(to: pixels))
        let zoom = 6, gap = 12
        let w = image.width + gap + part.width * zoom, h = max(image.height, part.height * zoom)
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: h - image.height, width: image.width, height: image.height))
        ctx.interpolationQuality = .none
        ctx.draw(part, in: CGRect(x: image.width + gap, y: h - part.height * zoom, width: part.width * zoom, height: part.height * zoom))
        return try #require(ctx.makeImage())
    }

    /// The square around the spinner view under `row`, in `crop`'s point space (the crop pads `rowRect` by 6).
    static func spinnerBox(in row: NSView, root: NSView, rowRect: NSRect) throws -> CGRect {
        let spinner = try #require(spinners(in: row).first { !$0.isHiddenOrHasHiddenAncestor && $0.indicator.plan.glyph != .none },
                                   "no spinner in \(row)")
        var r = root.convert(spinner.bounds, from: spinner).insetBy(dx: -2, dy: -2)
        let padded = rowRect.insetBy(dx: -6, dy: -6).intersection(root.bounds)
        r.origin.x -= padded.minX
        r.origin.y = root.isFlipped ? r.minY - padded.minY : padded.maxY - r.maxY
        return r
    }

    /// Every status indicator view under `view`.
    static func spinners(in view: NSView) -> [StatusIndicatorView] {
        (view as? StatusIndicatorView).map { [$0] } ?? view.subviews.flatMap { spinners(in: $0) }
    }

    /// A working workspace row and a collapsed loading group header, in that order.
    static func sidebarCrops(dark: Bool) throws -> [CGImage] {
        let harness = T.KindHarness(width: 260)
        defer { harness.window.close() }
        let root = try #require(harness.window.contentView)
        try AAPinnedNoCloseGalleryTests.theme(root, harness.window, dark: dark)
        // A test window's occlusion is not known yet: draw the rows as on a shown window, so the spinner
        // is the turning mark and not the still one a hidden window draws.
        harness.list.setWindowVisible(true)
        harness.sidebar.layoutSubtreeIfNeeded()
        var crops: [CGImage] = []
        for key in [SidebarRowKey.workspace(T.busy), .group(T.folded)] {
            let row = try harness.row(key)
            row.layoutSubtreeIfNeeded()
            let drawn = spinners(in: row).filter { !$0.isHiddenOrHasHiddenAncestor && $0.indicator.plan.glyph != .none }
            #expect(!drawn.isEmpty && drawn.allSatisfy { $0.indicator.plan.animation == .spin }, "\(key): \(drawn.map(\.indicator.plan))")
            let rect = root.convert(row.bounds, from: row)
            let image = try AAPinnedNoCloseGalleryTests.crop(root, rect)
            let scale = CGFloat(image.width) / rect.insetBy(dx: -6, dy: -6).intersection(root.bounds).width
            crops.append(try withZoom(image, spinner: try spinnerBox(in: row, root: root, rowRect: rect), scale: scale))
        }
        return crops
    }

    /// A working agent tab in a tab strip.
    static func tabCrop(dark: Bool) throws -> CGImage {
        let id = CmuxNextTabs.TabID("working")
        var working = TabItem(id: id, title: "Agent chat")
        working.indicator = .working(progress: nil)
        let model = TabStripModel(tabs: [working, TabItem(id: CmuxNextTabs.TabID("idle"), title: "Idle")], selectedID: id)
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 40))
        window.contentView = root
        strip.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: TabStripView.preferredHeight)
        root.addSubview(strip)
        window.orderFrontRegardless()
        try AAPinnedNoCloseGalleryTests.theme(root, window, dark: dark)
        strip.layoutSubtreeIfNeeded()
        let cell = try #require(strip.cells[id])
        cell.isWindowVisible = true
        cell.layoutLayers()
        let frame = root.convert(strip.convert(cell.frame, from: strip.tabsClip), from: strip)
        let image = try AAPinnedNoCloseGalleryTests.crop(root, frame)
        let spinner = try #require(cell.spinnerLayer)
        #expect(spinner.plan.animation == .spin, "tab: \(spinner.plan)")
        let padded = frame.insetBy(dx: -6, dy: -6).intersection(root.bounds)
        let scale = CGFloat(image.width) / padded.width
        let rootLayer = try #require(root.layer)
        // Layer conversion carries each layer's flip, so this is the spinner in the root's bottom-up space.
        var box = rootLayer.convert(spinner.layer.bounds, from: spinner.layer).insetBy(dx: -2, dy: -2)
        box.origin.x -= padded.minX
        box.origin.y = padded.maxY - box.maxY
        return try withZoom(image, spinner: box, scale: scale)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil; StatusIndicatorAppearance.shared.refresh() }
        // The shared config caches whether loops run; read it again with Reduce Motion off.
        StatusIndicatorAppearance.shared.refresh()
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "working-spinner-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let names = ["sidebar-row", "group-header", "tab"]
        var rows: [[CGImage]] = []
        for dark in [true, false] {
            let images = try Self.sidebarCrops(dark: dark) + [Self.tabCrop(dark: dark)]
            for (image, name) in zip(images, names) {
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
            }
            rows.append(images)
        }
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
        tar.arguments = ["cf", "working-spinner-gallery.tar", "working-spinner-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

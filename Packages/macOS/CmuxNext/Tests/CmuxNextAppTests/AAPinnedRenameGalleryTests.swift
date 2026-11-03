import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Crops for Lawrence msg 19583 ("double clicking pinned workspaces to rename has problem"): the pinned row
/// "cmux-chromium lead" (it has a trailing dot) under the pointer, the same row after a double-click, and an unpinned
/// row after a double-click, dark and light. Written under `pinned-rename-gallery/` with `all.png` (dark on top, light
/// below, the three crops side by side), bundled to `pinned-rename-gallery.tar` for `cmux-ci run --artifact`, so a
/// run before the fix and one after it compare.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAPinnedRenameGalleryTests {
    static let names = ["pinned-row-hover", "pinned-row-double-clicked", "unpinned-row-double-clicked"]

    /// The three crops in `names`' order.
    static func crops(dark: Bool) throws -> [CGImage] {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        var crops: [CGImage] = []
        do {
            let harness = PinnedRowDoubleClickRenameTests.Harness()
            defer { harness.close() }
            let root = try #require(harness.window.contentView)
            try AAPinnedNoCloseGalleryTests.theme(root, harness.window, dark: dark)
            harness.settle()
            var row = try harness.pin(PinnedRowDoubleClickRenameTests.pins[1].id)
            let title = row.convert(row.titleFrame, to: nil)
            let point = NSPoint(x: title.minX + 6, y: title.midY)
            harness.hover(point)
            row = try harness.pin(PinnedRowDoubleClickRenameTests.pins[1].id)
            let frame = root.convert(row.bounds, from: row)
            crops.append(try AAPinnedNoCloseGalleryTests.crop(root, frame))
            try harness.doubleClick(at: point)
            crops.append(try AAPinnedNoCloseGalleryTests.crop(root, frame))
        }
        do {
            let harness = PinnedRowDoubleClickRenameTests.Harness()
            defer { harness.close() }
            let root = try #require(harness.window.contentView)
            try AAPinnedNoCloseGalleryTests.theme(root, harness.window, dark: dark)
            harness.settle()
            let id = PinnedRowDoubleClickRenameTests.loose[1]
            var row = try #require(harness.list.rowViews[.workspace(id)] as? WorkspaceRowView)
            let title = row.convert(row.title.frame, to: nil)
            let point = NSPoint(x: title.minX + 6, y: title.midY)
            harness.hover(point)
            row = try #require(harness.list.rowViews[.workspace(id)] as? WorkspaceRowView)
            let frame = root.convert(row.bounds, from: row)
            try harness.doubleClick(at: point)
            crops.append(try AAPinnedNoCloseGalleryTests.crop(root, frame))
        }
        return crops
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "pinned-rename-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var rows: [[CGImage]] = []
        for dark in [true, false] {
            let images = try Self.crops(dark: dark)
            for (image, name) in zip(images, Self.names) {
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
            }
            rows.append(images)
        }
        // The crops side by side, dark on top and light below, each in a cell as wide as the widest crop.
        let gap = 16
        let cellW = rows.flatMap { $0 }.map(\.width).max() ?? 1, cellH = rows.flatMap { $0 }.map(\.height).max() ?? 1
        let columns = Self.names.count
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
        tar.arguments = ["cf", "pinned-rename-gallery.tar", "pinned-rename-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

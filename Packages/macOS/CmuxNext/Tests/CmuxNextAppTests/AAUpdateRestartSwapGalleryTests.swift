import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// The download card turning into Restart to Update, frame by frame, as the bottom slot places them (bottom
/// edges kept): 1 the download near its end, 2 halfway through the swap (the download fading out over the
/// ready card), 3 the ready card. The download's cancel hit square is outlined in red on every frame, so a
/// still shows whether Restart lands under it. Dark and light, under `update-restart-swap-gallery/`, bundled
/// to `update-restart-swap-gallery.tar` for `cmux-ci run --artifact`; run at a commit before and after a change.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAUpdateRestartSwapGalleryTests {
    static func frames(dark: Bool) throws -> [CGImage] {
        let download = UpdateRestartColumnTests.downloadCard(), ready = UpdateRestartColumnTests.readyCard()
        let width = UpdateRestartColumnTests.width
        let height = max(download.frame.height, ready.frame.height)
        let cancel = UpdateRestartColumnTests.fromBottom(download.trailingButton.frame, in: download)
        var images: [CGImage] = []
        for (downloadAlpha, readyAlpha) in [(1.0, 0.0), (0.5, 0.5), (0.0, 1.0)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 24, height: height + 24),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            defer { window.closeAfterTest() }
            let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
            window.contentView = root
            // Both cards end at the same bottom edge (unflipped root: y up), as in the slot.
            for (view, alpha) in [(ready as NSView, readyAlpha), (download as NSView, downloadAlpha)] where alpha > 0 {
                view.frame.origin = NSPoint(x: 12, y: 12)
                view.alphaValue = alpha
                root.addSubview(view)
            }
            let outline = NSView(frame: cancel.offsetBy(dx: 12, dy: 12))
            outline.wantsLayer = true
            outline.layer?.borderColor = NSColor.systemRed.cgColor
            outline.layer?.borderWidth = 1
            root.addSubview(outline)
            try AAPinnedNoCloseGalleryTests.theme(root, window, dark: dark)
            images.append(try AAPinnedNoCloseGalleryTests.crop(root, NSRect(x: 12, y: 12, width: width, height: height)))
            for view in [download, ready] { view.removeFromSuperview() }
        }
        return images
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "update-restart-swap-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var rows: [[CGImage]] = []
        for dark in [true, false] {
            let images = try Self.frames(dark: dark)
            for (index, image) in images.enumerated() {
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "frame-\(index + 1)-\(dark ? "dark" : "light").png"))
            }
            rows.append(images)
        }
        // The three frames side by side, dark on top and light below.
        let gap = 16
        let cellW = rows.flatMap { $0 }.map(\.width).max() ?? 1, cellH = rows.flatMap { $0 }.map(\.height).max() ?? 1
        let ctx = try #require(CGContext(data: nil, width: 3 * cellW + 4 * gap, height: 2 * cellH + 3 * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (row, images) in rows.enumerated() {
            for (col, image) in images.enumerated() {
                ctx.draw(image, in: CGRect(x: gap + col * (cellW + gap), y: gap + (1 - row) * (cellH + gap) + cellH - image.height,
                                           width: image.width, height: image.height))
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "update-restart-swap-gallery.tar", "update-restart-swap-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

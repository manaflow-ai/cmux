import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills of the Downloading Update card for Leo 2026-11-05 ("can we have, like, a better-looking update
/// downloading thing?"): three ways to lay out the bytes and time left (`direction-*`), then the
/// shipped one through every loading stage and the swap to Restart to Update (`state-*`), dark and light,
/// at the sidebar's default width. Written under `update-download-card-gallery/` with `all.png`, bundled
/// to `update-download-card-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAUpdateDownloadCardGalleryTests {
    static let width: CGFloat = 240
    static let expected: UInt64 = 265_300_000
    static let received: UInt64 = 115_000_000

    /// The shipped card with `rate` seconds of samples at 12.4 MB/s behind it (none: not measured yet).
    static func downloading(rateSeconds: Double?) -> SidebarNoticeCard {
        let transfer = UpdateTransfer.downloading(received: received, expected: expected)
        var shown = UpdateCard.downloading(transfer).presentation(version: "1.0.0", build: "100")
        if let rateSeconds {
            var rate = UpdateTransferRate()
            let start = Date(timeIntervalSinceReferenceDate: 0)
            let from = received - UInt64(12_400_000 * rateSeconds)
            rate.record(.downloading(.downloading(received: from, expected: expected)), at: start)
            rate.record(.downloading(transfer), at: start.addingTimeInterval(rateSeconds))
            if let line = rate.text(expected: expected), let bytes = shown.detail { shown.detail = bytes + "\n" + line }
        }
        return SidebarCardFeed.notice(shown, asked: true)
    }

    /// The directions: A (shipped) keeps the bytes line Leo knows and puts the time left under it; B leads
    /// with the time left; C puts it all on one line.
    static func directions() -> [(String, SidebarNoticeCard)] {
        let a = downloading(rateSeconds: 3)
        var b = a, c = a
        b.detail = "About 15 s left ·\u{2007}43%\n115.0 MB of 265.3 MB"
        c.detail = "115.0 MB of 265.3 MB ·\u{2007}43% · About 15 s left"
        return [("direction-a-bytes-then-speed", a), ("direction-b-time-first", b), ("direction-c-one-line", c)]
    }

    static func states() -> [(String, SidebarNoticeCard)] {
        let notice = { (card: UpdateCard) in SidebarCardFeed.notice(card.presentation(version: "1.0.0", build: "100"), asked: true) }
        return [
            ("state-1-checking", notice(.checking)),
            ("state-2-starting", notice(.downloading(.starting))),
            ("state-3-downloading-first-second", downloading(rateSeconds: nil)),
            ("state-4-downloading", downloading(rateSeconds: 3)),
            ("state-5-preparing", notice(.downloading(.preparing(0.6)))),
            ("state-6-installing", notice(.installing)),
        ]
    }

    static func ready() -> SidebarUpdateCard {
        SidebarCardFeed.updateCard(UpdateReadyCard(version: "nightly 200", isInstalling: false, automaticUpdates: true,
                                                   notes: UpdateReadyNotes(version: "nightly 200", notes: nil, fullNotesURL: nil)))
    }

    /// `view` drawn alone on the theme's window background, at its own size.
    static func render(_ view: NSView, dark: Bool) throws -> CGImage {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: view.frame.width + 24, height: view.frame.height + 24),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = root
        view.frame.origin = NSPoint(x: 12, y: 12)
        root.addSubview(view)
        try AAPinnedNoCloseGalleryTests.theme(root, window, dark: dark)
        return try AAPinnedNoCloseGalleryTests.crop(root, view.frame)
    }

    static func notice(_ card: SidebarNoticeCard, dark: Bool) throws -> CGImage {
        let view = SidebarNoticeCardView(motionPolicy: { MotionPolicy(speed: .fast, reduceMotion: true) })
        view.frame = NSRect(x: 0, y: 0, width: width, height: SidebarNoticeCardView.height(for: card))
        view.configure(card)
        return try render(view, dark: dark)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "update-download-card-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var rows: [[CGImage]] = []
        for dark in [true, false] {
            var images: [CGImage] = []
            for (name, card) in Self.directions() + Self.states() {
                let image = try Self.notice(card, dark: dark)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
                images.append(image)
            }
            let readyView = SidebarUpdateCardView(frame: .zero)
            readyView.frame = NSRect(x: 0, y: 0, width: Self.width, height: SidebarUpdateCardView.height(for: Self.ready()))
            readyView.configure(Self.ready())
            let ready = try Self.render(readyView, dark: dark)
            try AAGroupHeaderDensityGalleryTests.write(ready, to: out.appending(path: "state-7-ready-\(dark ? "dark" : "light").png"))
            images.append(ready)
            rows.append(images)
        }
        // Every still in a column, dark on the left and light on the right.
        let gap = 16
        let cellW = rows.flatMap { $0 }.map(\.width).max() ?? 1
        let heights = rows[0].map(\.height)
        let ctx = try #require(CGContext(data: nil, width: 2 * cellW + 3 * gap, height: heights.reduce(0, +) + (heights.count + 1) * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (column, images) in rows.enumerated() {
            var top = ctx.height - gap
            for image in images {
                top -= image.height
                ctx.draw(image, in: CGRect(x: gap + column * (cellW + gap), y: top, width: image.width, height: image.height))
                top -= gap
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "update-download-card-gallery.tar", "update-download-card-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

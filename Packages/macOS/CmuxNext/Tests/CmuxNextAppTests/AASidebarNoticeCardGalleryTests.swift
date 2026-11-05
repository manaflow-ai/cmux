import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills of the sidebar's notice card for Leo 2026-11-05, on the "Help Make cmux Faster?" hang-reports card ("why
/// is the text under it? Also giving negative space away ... the buttons and the subtitle text is in a different
/// indentation level"): the three ways to place its icon (`direction-*`, ``SidebarNoticeCardView/GlyphPlacement``) at
/// sidebars 220 and 260 pt wide, then every kind of notice card in the shipped placement (`card-*`), dark and light.
/// Written under `sidebar-notice-card-gallery/` with `all.png`, bundled to `sidebar-notice-card-gallery.tar` for
/// `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarNoticeCardGalleryTests {
    /// The card widths in sidebars 220 and 260 pt wide (``SidebarBottomCardSlot/cardWidth(in:)``).
    static var widths: [CGFloat] { [220, 260].map { SidebarBottomCardSlot.cardWidth(in: $0) } }

    static func directions() -> [(String, SidebarNoticeCard, CGFloat, SidebarNoticeCardView.GlyphPlacement)] {
        let ask = SidebarNoticeCardColumnTests.hangReportsAsk()
        return SidebarNoticeCardView.GlyphPlacement.allCases.enumerated().flatMap { index, placement in
            widths.map { width in
                ("direction-\(["a", "b", "c"][index])-\(placement)-\(Int(width))", ask, width, placement)
            }
        }
    }

    /// Every kind of notice card: a symbol with list lines, a heading and an x menu, a text button for the x, a switch,
    /// a running download.
    static func cards() -> [(String, SidebarNoticeCard)] {
        let tip = SidebarNoticeCard(id: "tip.palette", eyebrow: "Did you know?", title: "Find any action",
                                    detail: "Press ⇧⌘P and type what you want to do: every command, setting and workspace is there.",
                                    actions: [SidebarNoticeCard.Action(id: "try", title: "Try It", prominent: true)], shortcut: "⇧⌘P",
                                    dismissLabel: "Hide", dismissMenu: [SidebarNoticeCard.Action(id: "hide", title: "Hide")])
        let found = SidebarNoticeCard(id: "update.found", title: "Update Available", detail: "nightly 200 · Nov 5",
                                      actions: [SidebarNoticeCard.Action(id: "update", title: "Update", prominent: true)],
                                      dismissLabel: "Hide this update", dismissTitle: "Hide")
        let tidy = SidebarNoticeCard(id: "auto-archive.suggest", title: "2 idle workspaces", lines: ["api-refactor", "docs-pass"],
                                     actions: [SidebarNoticeCard.Action(id: "archive", title: "Archive", prominent: true),
                                               SidebarNoticeCard.Action(id: "always", title: "Always", isSwitch: true)],
                                     dismissLabel: "Not Now")
        let sparkles = SidebarNoticeCard(id: "ask.sparkles", symbol: "sparkles", title: "Name workspaces for you?",
                                         detail: "cmux can title a new workspace from its first message.",
                                         actions: [SidebarNoticeCard.Action(id: "yes", title: "Name Them", prominent: true),
                                                   SidebarNoticeCard.Action(id: "no", title: "Not Now")], dismissLabel: "Not Now")
        return [
            ("card-1-hang-reports", SidebarNoticeCardColumnTests.hangReportsAsk()),
            ("card-2-cloud-ask", SidebarNoticeCardColumnTests.cloudAsk),
            ("card-3-sparkles-ask", sparkles),
            ("card-4-tip", tip),
            ("card-5-update-found", found),
            ("card-6-tidy-up-switch", tidy),
            ("card-7-downloading", AAUpdateDownloadCardGalleryTests.downloading(rateSeconds: 3)),
        ]
    }

    static func notice(_ card: SidebarNoticeCard, width: CGFloat, placement: SidebarNoticeCardView.GlyphPlacement, dark: Bool) throws -> CGImage {
        let view = SidebarNoticeCardView(motionPolicy: { MotionPolicy(speed: .fast, reduceMotion: true) })
        view.glyphPlacement = placement
        view.frame = NSRect(x: 0, y: 0, width: width, height: SidebarNoticeCardView.height(for: card, width: width, placement: placement))
        view.configure(card)
        return try AAUpdateDownloadCardGalleryTests.render(view, dark: dark)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-notice-card-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let shipped = Self.cards().map { ($0.0, $0.1, Self.widths[0], SidebarNoticeCardView.GlyphPlacement.above) }
        var columns: [[CGImage]] = []
        for dark in [true, false] {
            var images: [CGImage] = []
            for (name, card, width, placement) in Self.directions() + shipped {
                let image = try Self.notice(card, width: width, placement: placement, dark: dark)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
                images.append(image)
            }
            columns.append(images)
        }
        // Every still in a column, dark on the left and light on the right.
        let gap = 16
        let cellW = columns.flatMap { $0 }.map(\.width).max() ?? 1
        let heights = columns[0].map(\.height)
        let ctx = try #require(CGContext(data: nil, width: 2 * cellW + 3 * gap, height: heights.reduce(0, +) + (heights.count + 1) * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (column, images) in columns.enumerated() {
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
        tar.arguments = ["cf", "sidebar-notice-card-gallery.tar", "sidebar-notice-card-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

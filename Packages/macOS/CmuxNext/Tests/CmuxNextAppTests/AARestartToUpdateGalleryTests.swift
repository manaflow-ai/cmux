import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills of the Update Ready card's Restart to Update in its three layouts (`SidebarUpdateCardLayout`:
/// card, compact, button only) for Leo's pick, now that a nightly downloads and unpacks by itself and
/// that click is all that is left (Leo 2026-11-10: "you simply click and it restarts with the new
/// version"; 2026-11-07: "we're gonna need a more, probably a more prominent sort of button"). Each
/// layout ready and installing, dark and light, at the sidebar's default width. Written under
/// `restart-to-update-gallery/` with `all.png`, bundled to `restart-to-update-gallery.tar` for
/// `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AARestartToUpdateGalleryTests {
    static let width: CGFloat = AAUpdateDownloadCardGalleryTests.width

    static func card(installing: Bool) -> SidebarUpdateCard {
        SidebarCardFeed.updateCard(UpdateReadyCard(version: "nightly 4269066", isInstalling: installing, automaticUpdates: true,
                                                   notes: UpdateReadyNotes(version: "nightly 4269066", notes: nil, fullNotesURL: nil)))
    }

    static func still(_ layout: SidebarUpdateCardLayout, installing: Bool, dark: Bool) throws -> CGImage {
        let card = card(installing: installing)
        let view = SidebarUpdateCardView(frame: .zero)
        view.layoutOverride = layout
        view.frame = NSRect(x: 0, y: 0, width: width, height: SidebarUpdateCardView.height(for: card, layout: layout))
        view.configure(card)
        return try AAUpdateDownloadCardGalleryTests.render(view, dark: dark)
    }

    /// Each layout's height holds its rows: compact and button only are shorter than the card.
    @Test func eachLayoutHasItsOwnHeight() {
        let card = Self.card(installing: false)
        let heights = SidebarUpdateCardLayout.allCases.map { SidebarUpdateCardView.height(for: card, layout: $0) }
        #expect(Set(heights).count == SidebarUpdateCardLayout.allCases.count, "two layouts share a height: \(heights)")
        #expect(SidebarUpdateCardView.height(for: card, layout: .compact) < SidebarUpdateCardView.height(for: card, layout: .card))
        #expect(SidebarUpdateCardView.height(for: card, layout: .button) < SidebarUpdateCardView.height(for: card, layout: .card))
        #expect(SidebarTunables.updateCardLayout.defaultValue == .card, "the default layout changed without Leo's pick")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "restart-to-update-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var rows: [[CGImage]] = []
        for dark in [true, false] {
            var images: [CGImage] = []
            for (index, layout) in SidebarUpdateCardLayout.allCases.enumerated() {
                for installing in [false, true] {
                    let image = try Self.still(layout, installing: installing, dark: dark)
                    let name = "variant-\(index + 1)-\(layout.rawValue)-\(installing ? "installing" : "ready")-\(dark ? "dark" : "light").png"
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: name))
                    images.append(image)
                }
            }
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
        tar.arguments = ["cf", "restart-to-update-gallery.tar", "restart-to-update-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

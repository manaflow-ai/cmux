import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import CmuxNextTestSupport
import Foundation
import Testing

/// The sidebar's update cards in a theme with a chosen accent (Soft Blue, `appearance.accent` blue),
/// for Leo 2026-11-27: "dont put this garish blue in man we dont need it to be blue or highlighted"
/// and "overlapping text here what do we doooo". Tone variants of Restart to Update (the
/// `SidebarUpdateButtonStyle` cases on one card: 1 the primary, 2 the app button, 3 inverted), the
/// Downloading card's bar and the Automatic Updates switch, and a notice with Hide and Cancel on one
/// row and a long title (the collision). Dark and light, written under `update-card-ink-gallery/`
/// with `all.png`, bundled to `update-card-ink-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAUpdateCardInkGalleryTests {
    static let width: CGFloat = AAUpdateDownloadCardGalleryTests.width
    static let variants: [SidebarUpdateButtonStyle] = [.primary, .bordered, .inverted]

    /// Soft Blue with the accent set to its blue: the look whose hue the cards used to pick up.
    static func scope(_ root: NSView, _ window: NSWindow, dark: Bool) throws -> ThemeScope {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        root.wantsLayer = true
        root.appearance = window.appearance
        let name = dark ? "Soft Blue" : "Soft Blue Light"
        var input = try AANestedGroupsGalleryTests.input(name)
        input.accent = .blue
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(name), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        return scope
    }

    static func render(_ view: NSView, dark: Bool) throws -> CGImage {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: view.frame.width + 24, height: view.frame.height + 24),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = root
        view.frame.origin = NSPoint(x: 12, y: 12)
        root.addSubview(view)
        _ = try scope(root, window, dark: dark)
        return try AAPinnedNoCloseGalleryTests.crop(root, view.frame)
    }

    static func ready(_ style: SidebarUpdateButtonStyle, dark: Bool) throws -> CGImage {
        let card = AARestartToUpdateGalleryTests.card(installing: false)
        let view = SidebarUpdateCardView(frame: .zero)
        view.layoutOverride = .card
        view.button.fixedStyle = style
        view.frame = NSRect(x: 0, y: 0, width: width, height: SidebarUpdateCardView.height(for: card, layout: .card))
        view.configure(card)
        return try render(view, dark: dark)
    }

    /// A notice with the text dismiss (Hide) and the card's own control (Cancel) on its first row,
    /// under a title long enough to reach them.
    static let collision = SidebarNoticeCard(
        id: "update", symbol: nil, title: "Update Available: nightly 4269066 with the new sidebar", detail: "258.0 MB · 58%",
        progress: .fraction(0.58), trailing: SidebarNoticeCard.Trailing(id: "cancel", symbol: "xmark", label: "Cancel"),
        dismissLabel: "Close", dismissTitle: "Hide")

    static func notice(_ card: SidebarNoticeCard, dark: Bool) throws -> CGImage {
        let view = SidebarNoticeCardView(motionPolicy: { MotionPolicy(speed: .fast, reduceMotion: true) })
        view.frame = NSRect(x: 0, y: 0, width: width, height: SidebarNoticeCardView.height(for: card, width: width))
        view.configure(card)
        return try render(view, dark: dark)
    }

    /// Hide and Cancel share the first row: neither sits on the other, and the title ends before both.
    @Test func hideAndCancelNeverOverlap() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let view = SidebarNoticeCardView(motionPolicy: { MotionPolicy(speed: .fast, reduceMotion: true) })
        view.frame = NSRect(x: 0, y: 0, width: Self.width, height: SidebarNoticeCardView.height(for: Self.collision, width: Self.width))
        window.contentView?.addSubview(view)
        view.configure(Self.collision)
        view.layoutSubtreeIfNeeded()
        let hide = view.dismissButton.frame, cancel = view.trailingButton.frame, title = view.titleLabel.frame
        #expect(!view.dismissButton.isHidden && !view.trailingButton.isHidden)
        #expect(!hide.intersects(cancel), "Cancel \(cancel) sits on Hide \(hide)")
        #expect(title.maxX <= min(hide.minX, cancel.minX), "the title \(title) runs under Hide \(hide) or Cancel \(cancel)")
    }

    /// With a chosen accent, none of the update cards' controls take its hue.
    @Test func aChosenAccentNeverFillsTheCards() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        window.contentView = root
        let scope = try Self.scope(root, window, dark: true)
        let card = AARestartToUpdateGalleryTests.card(installing: false)
        let ready = SidebarUpdateCardView(frame: NSRect(x: 0, y: 0, width: Self.width, height: SidebarUpdateCardView.height(for: card, layout: .card)))
        ready.layoutOverride = .card
        ready.button.fixedStyle = .primary
        root.addSubview(ready)
        ready.configure(card)
        let notice = SidebarNoticeCardView(motionPolicy: { MotionPolicy(speed: .fast, reduceMotion: true) })
        notice.frame = NSRect(x: 0, y: 0, width: Self.width, height: 96)
        root.addSubview(notice)
        notice.configure(SidebarNoticeCard(id: "update", title: "Downloading Update", detail: "57.3 MB of 257.1 MB · 22%", progress: .fraction(0.22)))
        root.layoutSubtreeIfNeeded()
        ready.button.updateLayer()
        ready.toggle.updateLayer()
        let (chosen, accent) = scope.perform { (Palette.hasChosenAccent, Palette.accentFill.cgColor) }
        #expect(chosen, "the gallery theme names no accent, so it proves nothing")
        #expect(ready.button.layer?.backgroundColor != accent, "Restart to Update is the accent's hue")
        #expect(ready.toggle.layer?.sublayers?.first?.backgroundColor != accent, "the Automatic Updates switch is the accent's hue")
        #expect(notice.bar.backgroundColor != accent, "the download bar is the accent's hue")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "update-card-ink-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var columns: [[CGImage]] = []
        for dark in [true, false] {
            let mode = dark ? "dark" : "light"
            var images: [CGImage] = []
            for (index, style) in Self.variants.enumerated() {
                let image = try Self.ready(style, dark: dark)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "variant-\(index + 1)-\(style.rawValue)-\(mode).png"))
                images.append(image)
            }
            let downloading = try Self.notice(AAUpdateDownloadCardGalleryTests.downloading(rateSeconds: 42), dark: dark)
            try AAGroupHeaderDensityGalleryTests.write(downloading, to: out.appending(path: "downloading-bar-\(mode).png"))
            let collision = try Self.notice(Self.collision, dark: dark)
            try AAGroupHeaderDensityGalleryTests.write(collision, to: out.appending(path: "hide-cancel-collision-\(mode).png"))
            images += [downloading, collision]
            columns.append(images)
        }
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
        tar.arguments = ["cf", "update-card-ink-gallery.tar", "update-card-ink-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

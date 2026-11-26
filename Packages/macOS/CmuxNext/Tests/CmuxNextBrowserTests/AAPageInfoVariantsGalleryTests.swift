import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// cmuxterm-hq RFD 0125 D10's gallery: the Page Info bubble today and in its three redraws on the shared menu
/// and card surfaces (``PageInfoLook``: `menu`, `card`, `band`), light and dark, on a secure page with two
/// permissions set, in the bubble's own card (``PageInfoCardView``). Written as PNGs under
/// `page-info-variants-gallery/` and bundled to `page-info-variants-gallery.tar` for `cmux-ci run --artifact`.
/// Runs only with `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAPageInfoVariantsGalleryTests {
    static func render(_ look: PageInfoLook, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let model = PageInfoModel()
        model.site = PageInfoSite(url: URL(string: "https://example.com/docs"), kind: .web(.secure))
        model.permissions = [
            SitePermissionState(kind: .camera, setting: .allow, isDefault: false),
            SitePermissionState(kind: .notifications, setting: .block, isDefault: false),
        ]
        let (card, size) = PageInfoLook.drawing(look) {
            let page = PageInfoPages(model: model, send: { _ in }).build()
            let card = PageInfoCardView(frame: NSRect(x: 0, y: 0, width: PageInfoStyle.bubbleWidth, height: 10))
            return (card, card.setContent(page))
        }
        // A margin of backdrop around the bubble so its corners and edge show.
        let margin: CGFloat = 16
        let bounds = NSRect(x: 0, y: 0, width: size.width + margin * 2, height: size.height + margin * 2)
        let window = NSWindow(contentRect: bounds.offsetBy(dx: 100, dy: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: bounds)
        root.wantsLayer = true
        root.appearance = window.appearance
        root.layer?.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
        window.contentView = root
        card.frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        root.addSubview(card)
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        CATransaction.flush()
        root.display()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = root.appending(path: "page-info-variants-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for look in PageInfoLook.allCases {
            for (mode, dark) in [("light", false), ("dark", true)] {
                let image = try Self.render(look, dark: dark)
                let url = out.appending(path: "\(look.rawValue)-\(mode).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "page-info-variants-gallery.tar", "page-info-variants-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// The Page Info cookies page after "Delete site data" failed on an unreadable cookie jar, light and dark.
/// `before` is what the old code showed: the counts read after the delete (an unreadable jar reads as none),
/// as if the data were gone. `after` says the delete failed, with its reason, in the same line. Written as PNGs
/// under `page-info-delete-failure-gallery/` and bundled to `page-info-delete-failure-gallery.tar` for
/// `cmux-ci run --artifact`. Runs only with `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAPageInfoDeleteFailureGalleryTests {
    enum Look: String, CaseIterable {
        case before
        case after
    }

    static func render(_ look: Look, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let model = PageInfoModel()
        model.site = PageInfoSite(url: URL(string: "https://example.com/a"), kind: .web(.secure))
        model.page = .cookies
        model.siteData = SiteDataSummary(entries: [])
        if look == .after { model.siteDataDeleteFailure = .cookiesUnreadable(reason: "cookie visit timed out") }
        let page = PageInfoPages(model: model, send: { _ in }).build()
        let width = PageInfoStyle.bubbleWidth
        page.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        page.layoutSubtreeIfNeeded()
        let height = max(80, page.fittingSize.height)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        root.layer?.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)).cgColor
        window.contentView = root
        page.frame = root.bounds
        page.autoresizingMask = [.width, .height]
        root.addSubview(page)
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
        let out = root.appending(path: "page-info-delete-failure-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for look in Look.allCases {
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
        tar.arguments = ["cf", "page-info-delete-failure-gallery.tar", "page-info-delete-failure-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

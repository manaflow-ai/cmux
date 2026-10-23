import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import Foundation
import Testing

/// A hibernated tab wakes to a picture in the frame that shows it (perf-lead.md row 15: "wake
/// shows a picture in < 10 ms"). Its picture is a JPEG of the full page, which takes 10 to 30 ms
/// to decode off the main thread, so the pane showed nothing for those frames. Each large
/// picture now also keeps a small decoded preview (a few hundred KB) that the placeholder shows
/// the moment it enters a window, until the full picture is decoded.
@MainActor @Suite struct HibernationWakePictureTests {
    private static func picture(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return try #require(context.makeImage())
    }

    /// A full-page picture keeps a decoded preview no larger than `previewPixelSize` on its long
    /// side, counted in the store's budget; a small picture decodes fast enough to need none.
    @Test func aLargePictureKeepsASmallDecodedPreview() async throws {
        let large = try #require(await HibernationSnapshots.compress(Self.picture(width: 2400, height: 1500)))
        let preview = try #require(large.preview, "a full-page picture kept no preview to show at once")
        #expect(max(preview.width, preview.height) <= HibernationSnapshots.previewPixelSize)
        #expect(abs(Double(preview.width) / Double(preview.height) - 1.6) < 0.02, "the preview was squeezed")

        let store = HibernationSnapshots()
        store.insert(large, for: "page")
        #expect(store.preview(for: "page") != nil)
        #expect(store.totalBytes == (large.data?.count ?? 0) + preview.bytesPerRow * preview.height, "the preview is not in the budget")

        let small = try #require(await HibernationSnapshots.compress(Self.picture(width: 400, height: 300)))
        #expect(small.preview == nil, "a small picture kept a preview it does not need")
    }

    /// The placeholder shows the preview in the same turn it enters a window, before any decode.
    @Test func thePlaceholderShowsItsPreviewTheMomentItIsShown() throws {
        let preview = try Self.picture(width: 384, height: 240)
        let full = try Self.picture(width: 2400, height: 1500)
        let tab = HibernatedBrowserTab(
            id: BrowserTabID(rawValue: "tab_wake_picture"), engine: .cef, profile: .default,
            state: BrowserTabState(url: URL(string: "https://example.com"), title: "Example"), favicon: nil,
            restoreState: .webKit(Data()), snapshot: { full }, preview: { preview })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(tab.contentView)
        let shown = try #require(tab.contentView as? NSImageView)
        #expect(shown.image != nil, "the woken tab showed an empty pane until its picture decoded")
        // What it shows is what the woken page's chrome keeps over the page until it draws
        // (`BrowserChromeView.holdPicture(whileWaking:)`): no decode, the same pixels.
        #expect(tab.wakePicture === preview, "the woken page would cover itself with another picture than the one shown")
    }
}

import AppKit
@testable import CmuxNextDesign
import Foundation
import ImageIO
import Testing
import CmuxNextDesignTokens
import CmuxNextWakeups

/// The wallpaper still a page's glass lenses (plans/cmux-next/glass-lens-DESIGN.md): where the
/// aspect-filled art lies in the page's CSS px, what a push carries, the encoded still, and which
/// backdrop a web view sits over.
@MainActor @Suite struct GlassBackdropTests {
    @Test func aspectFillCoversTheViewCentered() throws {
        // A 2:1 image in a 400x400 view: scaled to 800x400, overhanging 200 on each side.
        let wide = try #require(GlassBackdropRect.aspectFill(CGSize(width: 2000, height: 1000), in: CGRect(x: 0, y: 0, width: 400, height: 400)))
        #expect(wide == CGRect(x: -200, y: 0, width: 800, height: 400))
        // A 1:2 image in a 400x200 view: scaled to 400x800, overhanging 300 above and below.
        let tall = try #require(GlassBackdropRect.aspectFill(CGSize(width: 500, height: 1000), in: CGRect(x: 10, y: 20, width: 400, height: 200)))
        #expect(tall == CGRect(x: 10, y: -280, width: 400, height: 800))
        #expect(GlassBackdropRect.aspectFill(.zero, in: CGRect(x: 0, y: 0, width: 10, height: 10)) == nil)
        #expect(GlassBackdropRect.aspectFill(CGSize(width: 1, height: 1), in: .zero) == nil)
    }

    @Test func theRectIsInThePagesCSSPixelsFromItsTopLeft() throws {
        // The art fills a 1000x800 window (a 1600x800 image overhangs 300 on each side). The page
        // is a pane at x 300, 100 above the window's bottom, 400x500: its top edge is at y 600.
        let art = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let page = CGRect(x: 300, y: 100, width: 400, height: 500)
        let rect = try #require(GlassBackdropRect(imageSize: CGSize(width: 1600, height: 800), artFrame: art, pageFrame: page, zoom: 1))
        #expect(rect == GlassBackdropRect(x: -600, y: -200, width: 1600, height: 800))
        // Page zoom 2: every CSS px is two points.
        let zoomed = try #require(GlassBackdropRect(imageSize: CGSize(width: 1600, height: 800), artFrame: art, pageFrame: page, zoom: 2))
        #expect(zoomed == GlassBackdropRect(x: -300, y: -100, width: 800, height: 400))
        #expect(GlassBackdropRect(imageSize: CGSize(width: 1600, height: 800), artFrame: art, pageFrame: page, zoom: 0) == nil)
        #expect(GlassBackdropRect(imageSize: CGSize(width: 1600, height: 800), artFrame: art, pageFrame: .zero, zoom: 1) == nil)
    }

    @Test func theRectFollowsViewConversionInFlippedViews() throws {
        // The same math through AppKit: a flipped page view inside a window's content view.
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let art = NSView(frame: content.bounds)
        let column = FlippedView(frame: CGRect(x: 300, y: 100, width: 400, height: 600))
        let page = FlippedView(frame: CGRect(x: 0, y: 100, width: 400, height: 500)) // 100 below the column's top
        content.addSubview(art)
        content.addSubview(column)
        column.addSubview(page)
        let rect = try #require(GlassBackdropRect(imageSize: CGSize(width: 1600, height: 800), artFrame: art.convert(art.bounds, to: content),
                                                  pageFrame: page.convert(page.bounds, to: content), zoom: 1))
        // The page's top edge is 100 below the column's (y 700 in the content), at y 600: the art's
        // top (y 800) is 200 above it, its left edge (x -300) 600 left of the page's.
        #expect(rect == GlassBackdropRect(x: -600, y: -200, width: 1600, height: 800))
    }

    @Test func aPushCarriesOnlyWhatChangedAndTheImageOnlyWithANewKey() throws {
        let rect = GlassBackdropRect(x: 0, y: 0, width: 10, height: 10)
        let first = GlassBackdropPayload(key: "still-1", rect: rect, blur: 12, tint: "rgba(0, 0, 0, 0.5)")
        let all = try #require(first.changes(since: nil, image: "data:image/jpeg;base64,AA"))
        #expect(Set(all.keys) == ["key", "image", "rect", "blur", "tint"])
        #expect(all["image"] as? String == "data:image/jpeg;base64,AA")
        #expect(first.changes(since: first, image: "data:image/jpeg;base64,AA") == nil)
        var moved = first
        moved.rect = GlassBackdropRect(x: 5, y: 0, width: 10, height: 10)
        let rectOnly = try #require(moved.changes(since: first, image: "data:image/jpeg;base64,AA"))
        #expect(Set(rectOnly.keys) == ["rect"])
        var newArt = first
        newArt.key = "still-2"
        let image = try #require(newArt.changes(since: first, image: "data:image/jpeg;base64,BB"))
        #expect(Set(image.keys) == ["key", "image"])
        let gone = try #require(GlassBackdropPayload.none.changes(since: first, image: nil))
        #expect(gone["image"] is NSNull && gone["key"] is NSNull && gone["rect"] is NSNull)
        #expect(gone["tint"] as? String == "transparent")
    }

    @Test func theScriptCallsTheBackdropPush() throws {
        let script = try #require(GlassBackdropPayload.script(["key": "still-1", "image": "data:image/jpeg;base64,A/B", "blur": 4.0]))
        #expect(script.hasPrefix("window.cmuxTheme && window.cmuxTheme.backdrop && window.cmuxTheme.backdrop({"))
        #expect(script.contains("\"image\":\"data:image/jpeg;base64,A/B\""))
    }

    @Test func theTintIsACSSColorOrTransparent() {
        #expect(GlassBackdropPayload.css(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5)) == "rgba(255, 0, 0, 0.5)")
        #expect(GlassBackdropPayload.css(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0)) == "transparent")
        #expect(GlassBackdropPayload.css(nil) == "transparent")
    }

    @Test func theStillIsAJPEGNoWiderThanTheLimit() throws {
        let image = try #require(Self.bitmap(width: 2048, height: 1024))
        let url = try #require(GlassBackdropImages.jpegDataURL(image, maxPixelSize: 1024))
        let prefix = "data:image/jpeg;base64,"
        #expect(url.hasPrefix(prefix))
        let data = try #require(Data(base64Encoded: String(url.dropFirst(prefix.count))))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 1024 && decoded.height == 512)
    }

    @Test func oneArtImageIsEncodedOnceUnderOneKey() async throws {
        let images = GlassBackdropImages(maxPixelSize: 64)
        let art = NSImage(cgImage: try #require(Self.bitmap(width: 128, height: 64)), size: NSSize(width: 128, height: 64))
        let ready = AsyncStream<Void>.makeStream()
        let firstStill = images.still(art) { ready.continuation.yield() }
        let first = try #require(firstStill)
        #expect(first.dataURL == nil)
        for await _ in ready.stream { break }
        let secondStill = images.still(art, ready: {})
        let second = try #require(secondStill)
        #expect(second.key == first.key)
        #expect(second.dataURL?.hasPrefix("data:image/jpeg;base64,") == true)
        let other = NSImage(cgImage: try #require(Self.bitmap(width: 64, height: 64)), size: NSSize(width: 64, height: 64))
        let otherKey = images.still(other, ready: {})?.key
        #expect(otherKey != first.key)
    }

    @Test func aWebViewSitsOverTheNearestShownBackdropBelowIt() {
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let window = WindowMaterialView(frame: content.bounds)
        let pane = NSView(frame: content.bounds)
        let paneArt = WindowMaterialView(frame: pane.bounds)
        let host = NSView(frame: pane.bounds)
        content.addSubview(window)
        content.addSubview(pane)
        pane.addSubview(paneArt)
        pane.addSubview(host)
        let page = NSView(frame: host.bounds)
        host.addSubview(page)
        #expect(WindowMaterialView.glassBackdrop(behind: page) === paneArt)
        paneArt.isHidden = true
        #expect(WindowMaterialView.glassBackdrop(behind: page) === window)
        // A backdrop above the page's branch draws over it, not behind it.
        let over = WindowMaterialView(frame: content.bounds)
        content.addSubview(over)
        #expect(WindowMaterialView.glassBackdrop(behind: page) === window)
    }

    @Test func plainGlassPushesNothing() {
        let scripts = Scripts()
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let feed = GlassBackdropFeed(host: host, zoom: { 1 }, images: GlassBackdropImages(), mode: { .plain }) { scripts.all.append($0) }
        feed.refresh(newDocument: true)
        feed.refresh()
        #expect(scripts.all.isEmpty)
        #expect(feed.sent == nil)
    }

    /// The next-frame push waits for its window's node: a hidden window's page gets
    /// nothing, however many frames pass, until the window is seen or a capture vote holds it.
    @Test func aHiddenWindowsPageGetsNoPushUntilItsWindowIsSeenOrCaptured() async throws {
        let art = try Self.artFile()
        defer { try? FileManager.default.removeItem(at: art.deletingLastPathComponent()) }
        let stills = GlassBackdropImages(maxPixelSize: 64)
        let backdrop = try await GlassFeedWindow(art: art, store: BackdropImageStore(maxPixelSize: 64), stills: stills, own: .hidden)
        defer { backdrop.window.close() }
        let scheduler = FrameScheduler.testing(mediaTime: { 500 }) { _ in GlassFeedLink() }
        let scripts = Scripts()
        let feed = GlassBackdropFeed(host: backdrop.page, zoom: { 1 }, images: stills, mode: { .lens },
                                     scheduler: { _ in scheduler }) { scripts.all.append($0) }
        feed.setNeedsUpdate()
        for frame in 1...3 { scheduler.frameDidFire(timestamp: Double(frame), refreshInterval: 1.0 / 60) }
        #expect(scripts.all.isEmpty, "a hidden window's page got \(scripts.all.count) pushes")
        #expect(!scheduler.hasLink, "a parked push keeps the hidden window's link")

        let vote = backdrop.node.captureVote(reason: "test.screenshot", stayHidden: true)
        scheduler.frameDidFire(timestamp: 4, refreshInterval: 1.0 / 60)
        #expect(scripts.all.count == 1, "a captured hidden window's page was not pushed")
        #expect(scripts.all.first?.contains("\"image\"") == true)

        vote.release()
        backdrop.page.frame.origin.x += 10 // the page moves in its window: its rect changes
        feed.setNeedsUpdate()
        for frame in 5...7 { scheduler.frameDidFire(timestamp: Double(frame), refreshInterval: 1.0 / 60) }
        #expect(scripts.all.count == 1, "a hidden window's page was pushed after the capture ended")

        backdrop.node.set(.visible)
        scheduler.frameDidFire(timestamp: 8, refreshInterval: 1.0 / 60)
        #expect(scripts.all.count == 2, "the parked push did not run when the window showed")
        #expect(scripts.all.last?.contains("\"rect\"") == true)
    }

    /// A page moved to another window while its push waits for the hidden one: the push follows the
    /// new window's node and scheduler, and the old window showing later pushes nothing more.
    @Test func aParkedPushFollowsItsPageToAnotherWindow() async throws {
        let art = try Self.artFile()
        defer { try? FileManager.default.removeItem(at: art.deletingLastPathComponent()) }
        let store = BackdropImageStore(maxPixelSize: 64), stills = GlassBackdropImages(maxPixelSize: 64)
        let hidden = try await GlassFeedWindow(art: art, store: store, stills: stills, own: .hidden)
        let shown = try await GlassFeedWindow(art: art, store: store, stills: stills, own: .visible)
        defer {
            hidden.window.close()
            shown.window.close()
        }
        let hiddenFrames = FrameScheduler.testing(mediaTime: { 500 }) { _ in GlassFeedLink() }
        let shownFrames = FrameScheduler.testing(mediaTime: { 500 }) { _ in GlassFeedLink() }
        let scripts = Scripts()
        let page = hidden.page
        let feed = GlassBackdropFeed(host: page, zoom: { 1 }, images: stills, mode: { .lens },
                                     scheduler: { $0.window === shown.window ? shownFrames : hiddenFrames }) { scripts.all.append($0) }
        feed.setNeedsUpdate()
        hiddenFrames.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(scripts.all.isEmpty && !hiddenFrames.hasLink)

        shown.content.addSubview(page) // the pane moves to the other window and lays out there
        feed.setNeedsUpdate()
        #expect(shownFrames.hasLink, "the push did not move to the shown window's scheduler")
        shownFrames.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(scripts.all.count == 1, "the page was not pushed in the window it moved to")

        hidden.node.set(.visible)
        hiddenFrames.frameDidFire(timestamp: 3, refreshInterval: 1.0 / 60)
        shownFrames.frameDidFire(timestamp: 3, refreshInterval: 1.0 / 60)
        #expect(scripts.all.count == 1, "the old window's push ran after the page left it")
        #expect(!hiddenFrames.hasLink)
    }

    /// A PNG of the art in a fresh folder.
    static func artFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-glass-feed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("art.png")
        let image = try #require(bitmap(width: 128, height: 64))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private static func bitmap(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

final class Scripts {
    var all: [String] = []
}

/// A window whose backdrop shows decoded art, with a page view over it; the test sets its node.
@MainActor
struct GlassFeedWindow {
    let window: NSWindow
    let node: VisibilityNode
    let content: NSView
    let backdrop: WindowMaterialView
    let page: NSView

    /// Loads `art` into the backdrop and encodes its still in `stills`, so a push carries it at once.
    init(art: URL, store: BackdropImageStore, stills: GlassBackdropImages, own: Visibility,
         liveResize: @escaping @MainActor (NSView) -> Bool = { $0.inLiveResize }) async throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // Installed before any view asks, so the window's node is the test's, not AppKit's state.
        node = WindowVisibilitySource.of(window, events: WindowEvents(window: window, center: NotificationCenter()),
                                         read: { _ in own }).node
        content = NSView(frame: frame)
        window.contentView = content
        let backdrop = WindowMaterialView(frame: frame, images: store, videos: BackdropVideoPlayers(), liveResize: liveResize)
        self.backdrop = backdrop
        content.addSubview(backdrop)
        var look = WindowBackdrop(backgroundOpacity: 0.5, backgroundBlur: 0)
        look.selection = .file(path: art.path)
        backdrop.apply(look, tint: .black)
        await backdrop.artLoad?.value
        let image = try #require(backdrop.glassStill, "the backdrop has no still to lens")
        let ready = AsyncStream<Void>.makeStream()
        let still = try #require(stills.still(image) { ready.continuation.yield() })
        if still.dataURL == nil {
            for await _ in ready.stream { break }
        }
        page = NSView(frame: NSRect(x: 20, y: 20, width: 120, height: 80))
        content.addSubview(page)
    }
}

@MainActor
final class GlassFeedLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

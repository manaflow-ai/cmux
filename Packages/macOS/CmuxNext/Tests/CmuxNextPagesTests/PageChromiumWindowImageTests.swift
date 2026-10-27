import AppKit
@testable import CmuxNextCompat
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers

/// A window image (`debug.window_snapshot`, `cmux window screenshot`) paints Chromium's own image
/// of each React page the window shows on the Chromium engine: without the Screen Recording grant
/// the window server leaves out what Chromium's GPU process draws, so on a capture slot an agent
/// or Settings page came out blank.
@MainActor
struct PageChromiumWindowImageTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.window-image", resource: "window-image", processGroup: .solo, namespaces: [])
    /// A 1x1 PNG, as `Page.captureScreenshot` answers it.
    private static let onePixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-window-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func chromiumView(work: BackgroundWork? = nil) async throws -> (PageWebView, FakeChromiumPage) {
        let hosting = work.map(FakeChromiumHosting.init(work:)) ?? FakeChromiumHosting()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: hosting))
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        await view.chromiumStart?.value
        return (view, try #require(hosting.made.first))
    }

    @Test func aWindowListsTheChromiumPagesItShows() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let (shown, _) = try await chromiumView()
        shown.frame = NSRect(x: 100, y: 50, width: 300, height: 200)
        window.contentView?.addSubview(shown)
        let (hidden, _) = try await chromiumView()
        hidden.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        hidden.isHidden = true
        window.contentView?.addSubview(hidden)
        let (elsewhere, _) = try await chromiumView()
        // The New Tab spare waits in an alpha-0 parking view far outside the content.
        let parking = NSView(frame: NSRect(x: 100_000, y: 100_000, width: 800, height: 600))
        parking.alphaValue = 0
        window.contentView?.addSubview(parking)
        let (spare, _) = try await chromiumView()
        spare.frame = parking.bounds
        parking.addSubview(spare)
        // A page holding its paint is alpha 0 itself, even inside the content.
        let (holding, _) = try await chromiumView()
        holding.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        holding.alphaValue = 0
        window.contentView?.addSubview(holding)
        let (offWindow, _) = try await chromiumView()
        offWindow.frame = NSRect(x: 5_000, y: 0, width: 100, height: 100)
        window.contentView?.addSubview(offWindow)

        let listed = PageRegistry.shownChromiumPages(in: window)
        #expect(listed.map { ObjectIdentifier($0.page) } == [ObjectIdentifier(shown)])
        #expect(listed.first?.rect == NSRect(x: 100, y: 50, width: 300, height: 200))
        for view in [shown, hidden, elsewhere, spare, holding, offWindow] { view.close() }
        window.close()
    }

    @Test func aChromiumPageGivesItsImage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await chromiumView()
        page.answer = { method, _ in
            method == "Page.captureScreenshot" ? #"{"data":"\#(Self.onePixel)"}"# : nil
        }
        let image = try #require(await view.chromiumImage())
        #expect(image.width == 1 && image.height == 1)
        #expect(page.calls.contains { $0.method == "Page.captureScreenshot" })
        view.close()
    }

    /// A full-window screenshot (here 1024 x 1024: 4 MiB of pixels, far above the main thread's image gate) is parsed
    /// and decoded on the hosting's `.cpu` lane, for ``PageWebView/chromiumImage()`` and ``PageWebView/snapshot()``
    /// alike: the main thread records no cpu-intensive site and only wraps the pixels, the snapshot at the view's size.
    @Test func aLargeScreenshotIsDecodedOnTheCPULane() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // One .cpu slot: the sentinel item below runs after both decode items reported their runs.
        let lanes = OSAllocatedUnfairLock<[BlockingLane]>(initialState: [])
        let work = BackgroundWork(cpuWidth: 1, label: "test.page-screenshot", onRan: { lane, _, _, _ in lanes.withLock { $0.append(lane) } })
        let (view, page) = try await chromiumView(work: work)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let png = try Self.flatPNG(side: 1024)
        try #require(png.count < BlockingKind.cpuIntensiveImagePixelBytes)
        let reply = #"{"data":"\#(png.base64EncodedString())"}"#
        page.answer = { method, _ in method == "Page.captureScreenshot" ? reply : nil }
        let table = BlockingViolationTable(mode: .record)

        let (image, snapshot) = await BlockingViolationTable.$scoped.withValue(table) {
            (await view.chromiumImage(), await view.snapshot())
        }
        try await work.run(.userVisible, mayBlock: .cpu) {}
        await table.flush()

        #expect(image?.width == 1024 && image?.height == 1024)
        #expect(snapshot?.size == NSSize(width: 300, height: 200))
        #expect(lanes.withLock { $0.filter { $0 == .cpu }.count } >= 2, "a screenshot was not decoded on the .cpu lane")
        #expect(table.sites.filter { $0.kind == .cpuIntensive }.isEmpty, "a screenshot was decoded on the main thread: \(table.sites)")
        view.close()
        await work.shutdown()
    }

    /// A `side` x `side` PNG of one colour: a few KiB of data, `side` x `side` x 4 bytes of pixels.
    private static func flatPNG(side: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(context.makeImage())
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return encoded as Data
    }
}

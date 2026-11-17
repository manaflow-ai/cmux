import AppKit
import CCmuxLaunchRecordFFI
import CmuxNextControl
import CmuxNextScreenshots
import Foundation
import Testing
@testable import CmuxNextLaunchCapture

/// A window's launch image (`LaunchWindowCapture`): a Chromium page region shows the page's cached image only
/// while Rust's age rule says it still shows the page, else the theme's plain fill, never a stale page's
/// pixels; a publish hands its image to the launch record only while the window has not moved on.
@MainActor
struct LaunchWindowCaptureTests {
    private static func sRGB() throws -> CGColorSpace { try #require(CGColorSpace(name: CGColorSpace.sRGB)) }

    /// A `side` x `side` (or `side` x `height`) opaque image of one color.
    private static func solid(_ side: Int, height: Int? = nil, red: Double, green: Double, blue: Double) throws -> CGImage {
        let height = height ?? side
        let context = try #require(CGContext(data: nil, width: side, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: try Self.sRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: height))
        return try #require(context.makeImage())
    }

    /// The RGBA bytes of `image`'s pixel at (`x`, `y`) from its top left.
    private static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: try Self.sRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return bytes
    }

    private static func region(taken: UInt64?, version: Int?, page: Int, composite: UInt64) -> LaunchPageRegion {
        LaunchPageRegion(imageTakenAt: taken, imageVersion: version, pageVersion: page, pageChangedAt: nil, compositeAt: composite)
    }

    /// A page image of another version (the page navigated), with no version, or none at all: the region is the
    /// plain fill. Red is the stale page; the fill is the theme's dark gray.
    @Test func staleOrMissingPageImageIsPlainFill() throws {
        let stale = try Self.solid(4, red: 1, green: 0, blue: 0)
        let fill = try #require(LaunchWindowCapture.fillImage(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)))
        let cases = [Self.region(taken: 1_000, version: 1, page: 2, composite: 2_000),
                     Self.region(taken: 1_000, version: nil, page: 2, composite: 2_000),
                     Self.region(taken: 1_000, version: 2, page: 2, composite: 1_000 + 120_001),
                     Self.region(taken: nil, version: nil, page: 2, composite: 2_000)]
        for region in cases {
            #expect(LaunchWindowCapture.regionImage(cached: stale, region: region, fill: fill) === fill, "\(region)")
        }
        #expect(LaunchWindowCapture.regionImage(cached: nil, region: Self.region(taken: 1_000, version: 2, page: 2, composite: 2_000),
                                                fill: fill) === fill)
    }

    #if canImport(CCmuxLaunchImageFFI)
    /// A page image of the page's version, taken shortly before the composite, is painted.
    @Test func currentPageImageIsPainted() throws {
        let page = try Self.solid(4, red: 0, green: 0, blue: 1)
        let fill = try #require(LaunchWindowCapture.fillImage(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)))
        let region = Self.region(taken: 1_000, version: 7, page: 7, composite: 2_000)
        #expect(LaunchWindowCapture.regionImage(cached: page, region: region, fill: fill) === page)
    }
    #endif

    /// The composite paints the plain fill over the page region's pixels and leaves the rest of the window
    /// (the terminal, the chrome) as the window server gave it.
    @Test func plainFillCoversThePageRegionOnly() throws {
        // A 20 x 10 point window at 2x: green everywhere (what the window server gave), page on the right half.
        let base = try Self.solid(40, height: 20, red: 0, green: 1, blue: 0)
        let fill = try #require(LaunchWindowCapture.fillImage(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)))
        let image = LaunchWindowCapture.compose(base: base, windowSize: CGSize(width: 20, height: 10),
                                                layers: [.page(fill, NSRect(x: 10, y: 0, width: 10, height: 10))])
        let left = try Self.pixel(image, x: 5, y: 10), right = try Self.pixel(image, x: 35, y: 10)
        #expect(left[1] > 200 && left[0] < 30, "the terminal side keeps its pixels: \(left)")
        #expect(right[1] < 60 && right[0] < 60 && right[2] < 60, "the page side is the plain fill: \(right)")
    }

    /// The record's image dictionary takes a hand-off from any thread and the writer's snapshot reads it.
    @Test func recordImagesTakeAHandOffOffTheMainActor() async {
        let images = LaunchRecordImages()
        await Task.detached { images.set(LaunchRecordImage(key: "1/w/1", pixelWidth: 4, pixelHeight: 2), forWindow: "w") }.value
        #expect(images.all["w"]?.key == "1/w/1")
        images.set(nil, forWindow: "w")
        #expect(images.all["w"] == nil)
    }

    #if canImport(CCmuxLaunchImageFFI)
    /// A publish hands its image to the record only while the window has not moved on since the capture
    /// began (review F2 of #44472): a change between them drops the hand-off, and the file is not named.
    @Test func publishHandsOffOnlyWhileCurrent() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "launch-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LaunchImageStore(directory: directory, info: [:])
        let blue = try Self.solid(4, red: 0, green: 0, blue: 1)
        let png = try #require(blue.pngData())
        let schedule = LaunchImageSchedule()
        _ = schedule.note(.shown, at: 1)
        _ = schedule.note(.changed, at: 2)
        #expect(schedule.takeDue(at: 10_000))
        let images = LaunchRecordImages()
        let epoch = schedule.epoch
        var handed = false
        let first = store.publish(windowID: "w", png: png) { image in
            handed = schedule.whileCurrent(epoch) { images.set(image, forWindow: "w") }
        }
        #expect(handed && images.all["w"]?.key == first?.key && first?.pixelWidth == 4)
        // A change lands between the capture and its publish: nothing is handed over.
        _ = schedule.note(.changed, at: 10_001)
        handed = false
        let second = store.publish(windowID: "w", png: png) { image in
            handed = schedule.whileCurrent(epoch) { images.set(image, forWindow: "w") }
        }
        #expect(second != nil && !handed && images.all["w"]?.key == first?.key)
    }
    #endif

    /// What the record says of a window is what the stage-0 window checks (record v2, cmux-launch-shell): the
    /// window's backing scale (never 0, which reads as a v1 record), its display's frame (`NSScreen.frame`), its
    /// look and full screen state, and an image of frame x scale pixels within 1 px; written and read back
    /// through the record's C ABI.
    @Test func recordCarriesTheWindowsV2Fields() throws {
        let window = NSWindow(contentRect: NSRect(x: 40, y: 60, width: 301, height: 203), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false // a window made in code would be released twice by close() under ARC
        defer { window.close() }
        let (width, height) = LaunchWindowCapture.imagePixelSize(window.frame.size, scale: window.backingScaleFactor)
        let snapshot = LaunchWindowCapture.recordWindow(
            LaunchRecordWindowSnapshot(id: "w", frame: .zero, imageKey: "4294+abc123/w/3",
                                       imagePixelSize: (UInt32(width), UInt32(height))),
            of: window, dark: true, followsSystem: true)
        let directory = FileManager.default.temporaryDirectory.appending(path: "launch-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "launch-record.bin")
        #expect(LaunchRecordEncoding.write(LaunchRecordSnapshot(windows: [snapshot]), to: url))
        var read = CmuxLaunchWindow()
        #expect(cmux_launch_record_windows(url.path, &read, 1) == 1)
        let key = withUnsafeBytes(of: &read.image_key) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #expect(key == "4294+abc123/w/3", "a key, never a path")
        #expect(read.backing_scale == Double(window.backingScaleFactor) && read.backing_scale > 0)
        let screen = window.screen?.frame ?? .zero
        #expect(CGRect(x: read.screen_frame_x, y: read.screen_frame_y, width: read.screen_frame_width,
                       height: read.screen_frame_height) == screen)
        if let shown = window.screen { #expect(NSScreen.screens.contains { $0.frame == shown.frame }) }
        #expect(CGRect(x: read.frame_x, y: read.frame_y, width: read.frame_width, height: read.frame_height) == window.frame)
        #expect(read.appearance == 1 && read.appearance_follows_system == 1 && read.fullscreen == 0)
        #expect(abs(Double(read.image_pixel_width) - read.frame_width * read.backing_scale) <= 1)
        #expect(abs(Double(read.image_pixel_height) - read.frame_height * read.backing_scale) <= 1)
    }

    #if canImport(CCmuxLaunchImageFFI)
    /// A published image's record key is `<build>/<window key>/<generation>` (the stage-0 window's
    /// `ImageKey`), naming `<image dir>/<window key>.<generation>.png`, the file the publish wrote.
    @Test func publishedImageKeyNamesItsFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "launch-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LaunchImageStore(directory: directory, info: ["CFBundleVersion": "4294", "CMUXCommit": "abc123"])
        let blue = try Self.solid(4, red: 0, green: 0, blue: 1)
        let png = try #require(blue.pngData())
        var handed: LaunchRecordImage?
        let image = try #require(store.publish(windowID: "w", png: png) { handed = $0 })
        let parts = image.key.split(separator: "/").map(String.init)
        #expect(handed?.key == image.key && parts.count == 3 && parts[0] == "4294+abc123" && parts[1] == "w")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "\(parts[1]).\(parts[2]).png").path))
    }
    #endif
}

import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// macOS's Dynamic desktop in the app (`appearance.backgroundDynamic: "time"`): a dynamic HEIC's
/// frame follows the sun (`solar`) or the clock (`h24`), and a new picture crossfades in.
@MainActor @Suite(.serialized) struct BackdropDynamicFramesTests {
    static let sanFrancisco = BackdropLocation(latitude: 37.7749, longitude: -122.4194)

    /// Writes a HEIC of one solid frame per color with `apple_desktop:<name>` metadata `plist`.
    static func heic(_ colors: [NSColor], name: String, plist: [String: Any], to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, colors.count, nil))
        for (index, color) in colors.enumerated() {
            let context = try #require(CGContext(data: nil, width: 32, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(try #require(color.usingColorSpace(.sRGB)).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 20))
            let image = try #require(context.makeImage())
            guard index == 0 else { CGImageDestinationAddImage(destination, image, nil); continue }
            let metadata = CGImageMetadataCreateMutable()
            let namespace = "http://ns.apple.com/namespace/1.0/" as CFString
            CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace, "apple_desktop" as CFString, nil)
            let value = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).base64EncodedString()
            let tag = try #require(CGImageMetadataTagCreate(namespace, "apple_desktop" as CFString, name as CFString, .string, value as CFString))
            CGImageMetadataSetTagWithPath(metadata, nil, "apple_desktop:\(name)" as CFString, tag)
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
        }
        #expect(CGImageDestinationFinalize(destination))
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dynamic-frames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func calendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        return calendar
    }

    static func at(_ hour: Int, _ minute: Int = 0) throws -> Date {
        try #require(calendar().date(from: DateComponents(year: 2026, month: 6, day: 21, hour: hour, minute: minute)))
    }

    /// Four sun positions: night (0), morning (1), noon (2), evening (3). The frame of a moment is
    /// the position nearest the sun.
    @Test func solarFramesFollowTheSun() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Solar.heic")
        let positions: [[String: Any]] = [
            ["i": 0, "a": -40.0, "z": 0.0], ["i": 1, "a": 20.0, "z": 80.0],
            ["i": 2, "a": 75.0, "z": 180.0], ["i": 3, "a": 20.0, "z": 280.0],
        ]
        try Self.heic([.black, .orange, .white, .red], name: "solar", plist: ["si": positions, "ap": ["l": 2, "d": 0]], to: url)
        let frames = try #require(BackdropDynamicFrames.read(contentsOf: url))
        #expect(frames.solar.count == 4 && frames.light == 2 && frames.dark == 0)
        let calendar = try Self.calendar()
        #expect(frames.frame(at: try Self.at(1), location: Self.sanFrancisco, calendar: calendar) == 0)
        #expect(frames.frame(at: try Self.at(8), location: Self.sanFrancisco, calendar: calendar) == 1)
        #expect(frames.frame(at: try Self.at(13, 10), location: Self.sanFrancisco, calendar: calendar) == 2)
        #expect(frames.frame(at: try Self.at(18), location: Self.sanFrancisco, calendar: calendar) == 3)
        // The next change from the morning frame lands between 08:00 and noon, to the second.
        let change = try #require(frames.nextChange(after: try Self.at(8), location: Self.sanFrancisco, calendar: calendar))
        let (morning, noon) = (try Self.at(8), try Self.at(12))
        #expect(change > morning && change < noon)
        #expect(frames.frame(at: change, location: Self.sanFrancisco, calendar: calendar) != 1)
        #expect(frames.frame(at: change.addingTimeInterval(-1), location: Self.sanFrancisco, calendar: calendar) == 1)
        // Read once per path: the cache answers the same frames.
        #expect(BackdropDynamicFrames.read(contentsOf: url) == frames)
    }

    /// h24: frames start at fractions of the local day; before the first, the last one shows.
    @Test func clockFramesFollowTheLocalDay() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Clock.heic")
        let times: [[String: Any]] = [["i": 0, "t": 0.25], ["i": 1, "t": 0.5], ["i": 2, "t": 0.75]]
        try Self.heic([.orange, .white, .black], name: "h24", plist: ["ti": times, "ap": ["l": 1, "d": 2]], to: url)
        let frames = try #require(BackdropDynamicFrames.read(contentsOf: url))
        let calendar = try Self.calendar()
        #expect(frames.frame(at: try Self.at(3), location: Self.sanFrancisco, calendar: calendar) == 2)
        #expect(frames.frame(at: try Self.at(6), location: Self.sanFrancisco, calendar: calendar) == 0)
        #expect(frames.frame(at: try Self.at(12, 30), location: Self.sanFrancisco, calendar: calendar) == 1)
        #expect(frames.frame(at: try Self.at(20), location: Self.sanFrancisco, calendar: calendar) == 2)
        let change = try #require(frames.nextChange(after: try Self.at(7), location: Self.sanFrancisco, calendar: calendar))
        #expect(abs(change.timeIntervalSince(try Self.at(12))) <= 1)
    }

    /// A light/dark-only picture follows the sun: light above -6 degrees, dark below.
    @Test func appearancePairsFollowTheSunsAltitude() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Pair.heic")
        try Self.heic([.white, .black], name: "apr", plist: ["l": 0, "d": 1], to: url)
        let frames = try #require(BackdropDynamicFrames.read(contentsOf: url))
        let calendar = try Self.calendar()
        #expect(frames.frame(at: try Self.at(12), location: Self.sanFrancisco, calendar: calendar) == 0)
        #expect(frames.frame(at: try Self.at(23), location: Self.sanFrancisco, calendar: calendar) == 1)
    }

    /// A moment draws its pinned frame; a pair draws the side of the view's appearance.
    @Test func momentsAndPairsDecodeTheirPicture() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Solar.heic")
        try Self.heic([.black, .red, .white], name: "solar", plist: ["si": [["i": 1, "a": 10.0, "z": 90.0]], "ap": ["l": 2, "d": 0]], to: url)
        let store = BackdropImageStore(maxPixelSize: 32)
        let red = try #require(await store.image(.moment(path: url.path, frame: 1, dark: false)))
        #expect(try AppleWallpapersTests.red(red) > 200)
        let white = folder.appendingPathComponent("White.heic"), black = folder.appendingPathComponent("Black.heic")
        try AppleWallpapersTests.heic([.white], to: white)
        try AppleWallpapersTests.heic([.black], to: black)
        let pair = BackdropSelection.pair(light: .file(path: white.path), dark: .file(path: black.path))
        #expect(pair.followsAppearance)
        #expect(pair.resolved(dark: true) == .file(path: black.path))
        let dark = try #require(await store.image(pair, dark: true))
        #expect(try AppleWallpapersTests.red(dark) < 50)
        #expect(store.cached(pair, dark: true) === dark)
    }

    /// A new picture waits for its decode with the old one shown, then the art layer's contents
    /// crossfade; the art view keeps its frame and bounds. Reduce Motion swaps at once.
    @Test func aNewPictureCrossfadesInPlace() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("First.heic"), second = folder.appendingPathComponent("Second.heic")
        let third = folder.appendingPathComponent("Third.heic")
        try AppleWallpapersTests.heic([.white], to: first)
        try AppleWallpapersTests.heic([.black], to: second)
        try AppleWallpapersTests.heic([.red], to: third)
        Motion.reduceMotionOverride = false
        // The panes' fades play at the default motion settings, whatever an earlier test left.
        let design = DesignSettings.shared
        let saved = (design.animationSpeed, design.animationsEnabled, design.disabledAnimationCategories, design.calmMode)
        (design.animationSpeed, design.animationsEnabled, design.disabledAnimationCategories) = (.fast, true, [])
        design.calmMode = .off
        defer {
            Motion.reduceMotionOverride = nil
            (design.animationSpeed, design.animationsEnabled, design.disabledAnimationCategories, design.calmMode) = saved
        }
        #expect(Motion.panes.animatesFades)
        let store = BackdropImageStore(maxPixelSize: 32)
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 64, height: 40), images: store)
        view.crossfadesOffScreen = true
        var backdrop = WindowBackdrop(backgroundOpacity: 0.5, backgroundBlur: 0)
        backdrop.selection = .file(path: first.path)
        view.apply(backdrop, tint: .black)
        await view.artLoad?.value
        let layer = try #require(view.artView.layer)
        let shown = try #require(layer.contents as? NSImage)
        #expect(try AppleWallpapersTests.red(shown) > 200)
        let (frame, bounds) = (view.artView.frame, view.artView.bounds)

        backdrop.selection = .file(path: second.path)
        view.apply(backdrop, tint: .black)
        // Until the new picture decodes, the old one stays (no flash to the theme color).
        #expect(layer.contents as? NSImage === shown)
        await view.artLoad?.value
        #expect(try AppleWallpapersTests.red(try #require(layer.contents as? NSImage)) < 50)

        // A decoded picture crossfades in the same turn (read before a commit can end an
        // off-screen layer's animation).
        for dark in [false, true] { _ = await store.image(.file(path: third.path), dark: dark) }
        backdrop.selection = .file(path: third.path)
        view.apply(backdrop, tint: .black)
        #expect(layer.animation(forKey: "contents") != nil, "the swap crossfades")
        #expect(try AppleWallpapersTests.red(try #require(layer.contents as? NSImage)) > 200)
        #expect(view.artView.frame == frame && view.artView.bounds == bounds)
        #expect(!view.artView.isHidden)

        Motion.reduceMotionOverride = true
        layer.removeAllAnimations()
        backdrop.selection = .file(path: second.path)
        view.apply(backdrop, tint: .black)
        #expect(try AppleWallpapersTests.red(try #require(layer.contents as? NSImage)) < 50)
        #expect(layer.animation(forKey: "contents") == nil, "Reduce Motion swaps at once")
    }
}

import AppKit
@testable import CmuxNextBrowser
#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
#endif
import CmuxNextIcons
import CmuxNextWakeups
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers

/// Images bound to layers are decoded off the main thread (p03-rendering-121): the Extensions bubble's icons and a
/// toolbar action's icon are read and decoded on a BackgroundWork lane through ``IconAssetDecode``, to pixels at the
/// size they draw, and only the decoded bitmap reaches the main thread. Before, each 512 px PNG was read and decoded
/// on the main thread as the bubble rendered (`blockingNSImage`), one cpu-intensive site per icon. Chrome loads an
/// extension's icons through `ImageLoader` on its thread pool and replies to the UI thread
/// (extensions/browser/image_loader.cc).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ExtensionIconOffMainDecodeTests {
    /// A 512 px square PNG: 1 MiB of pixels, past the main thread's image gate.
    static let side = 512

    /// The lanes the work ran items on, in order.
    nonisolated final class LaneLog: Sendable {
        private let lanes = OSAllocatedUnfairLock<[BlockingLane]>(initialState: [])
        var ran: [BlockingLane] { lanes.withLock { $0 } }
        func record(_ lane: BlockingLane) { lanes.withLock { $0.append(lane) } }
    }

    nonisolated static func png(side: Int) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fillEllipse(in: CGRect(x: 8, y: 8, width: side - 16, height: side - 16))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func iconFile(side: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "extension-icon-\(UUID().uuidString).png")
        try png(side: side).write(to: url)
        return url
    }

    /// Main run loop passes, where the lanes' replies arrive, until `done` or 5 s.
    static func spin(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) }
    }

    /// The icon one render of the bubble shows for `info`.
    static func icon(_ icons: ExtensionIconCache, _ info: BrowserExtensionInfo) -> NSImage {
        icons.images(for: [info], pngs: [:])[0]
    }

    static func pixels(_ image: NSImage) -> Int? {
        image.representations.first.map { max($0.pixelsWide, $0.pixelsHigh) }
    }

    /// The bubble asks for a 512 px icon file: it shows the puzzle piece at once, reads and decodes the file on the
    /// `.files` lane, and the icon it shows after the arrival is the 20 pt icon with 40 px behind it.
    @Test func aBubbleIconIsReadAndDecodedOffTheMainThread() async throws {
        let url = try Self.iconFile(side: Self.side)
        defer { try? FileManager.default.removeItem(at: url) }
        let log = LaneLog()
        let work = BackgroundWork(label: "test.extension-icons", onRan: { lane, _, _, _ in log.record(lane) })
        let icons = ExtensionIconCache(side: 20, work: work, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        var arrivals = 0
        icons.onLoad = { arrivals += 1 }
        let info = BrowserExtensionInfo(id: "ext", name: "Ext", iconPath: url.path)

        let first = Self.icon(icons, info)
        #expect(first.accessibilityDescription == "Ext", "an icon not decoded yet shows the puzzle piece")
        _ = Self.icon(icons, info)
        Self.spin { arrivals == 1 }

        let shown = Self.icon(icons, info)
        #expect(arrivals == 1)
        #expect(icons.loads == 1, "a render while the icon was on its way read the file again")
        #expect(log.ran == [.files])
        #expect(shown.size == NSSize(width: 20, height: 20))
        #expect(Self.pixels(shown) == 40)
        #expect(Self.icon(icons, info) === shown, "a decoded icon is kept")
        await work.shutdown()
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// The main thread's part of a bubble icon (the request, the arrival, every render after it) decodes nothing:
    /// no cpu-intensive site, where a 512 px decode on the main thread is one.
    @Test func aBubbleIconDecodesNothingOnTheMainThread() async throws {
        let url = try Self.iconFile(side: Self.side)
        defer { try? FileManager.default.removeItem(at: url) }
        try #require(Self.side * Self.side * 4 > BlockingKind.cpuIntensiveImagePixelBytes)
        let work = BackgroundWork(label: "test.extension-icons-main")
        let icons = ExtensionIconCache(side: 20, work: work, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        var arrivals = 0
        icons.onLoad = { arrivals += 1 }
        let info = BrowserExtensionInfo(id: "ext", name: "Ext", iconPath: url.path)
        let table = BlockingViolationTable(mode: .record)

        BlockingViolationTable.$scoped.withValue(table) {
            _ = Self.icon(icons, info)
            Self.spin { arrivals == 1 }
            _ = Self.icon(icons, info)
        }
        await table.flush()

        #expect(arrivals == 1)
        #expect(table.sites.filter { $0.kind == .cpuIntensive || $0.kind == .fileIO }.isEmpty,
                "the icon was read or decoded on the main thread: \(table.sites)")
        await work.shutdown()
    }
    #endif

    /// A render of 40 rows reads their icons in one lane item and re-renders once when they come, not once per icon.
    @Test func oneRendersIconsArriveTogether() async throws {
        let urls = try (0..<40).map { _ in try Self.iconFile(side: 64) }
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        let log = LaneLog()
        let work = BackgroundWork(label: "test.extension-icons-batch", onRan: { lane, _, _, _ in log.record(lane) })
        let icons = ExtensionIconCache(side: 20, work: work, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        var arrivals = 0
        icons.onLoad = { arrivals += 1 }
        let infos = urls.enumerated().map { BrowserExtensionInfo(id: "ext\($0)", name: "Ext \($0)", iconPath: $1.path) }

        _ = icons.images(for: infos, pngs: [:])
        Self.spin { arrivals == 1 }
        for _ in 0..<4 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) }

        #expect(arrivals == 1)
        #expect(log.ran == [.files])
        #expect(icons.loads == 40)
        #expect(icons.images(for: infos, pngs: [:]).allSatisfy { Self.pixels($0) == 40 })
        await work.shutdown()
    }

    /// The rows went (``ExtensionIconCache/removeAll()``) while an icon was on its way: its arrival is dropped, and
    /// the next render asks for it again.
    @Test func anArrivalAfterTheRowsWentIsDropped() async throws {
        let url = try Self.iconFile(side: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        let work = BackgroundWork(label: "test.extension-icons-drop")
        let icons = ExtensionIconCache(side: 20, work: work, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        var arrivals = 0
        icons.onLoad = { arrivals += 1 }
        let info = BrowserExtensionInfo(id: "ext", name: "Ext", iconPath: url.path)

        _ = Self.icon(icons, info)
        icons.removeAll()
        _ = Self.icon(icons, info)
        Self.spin { arrivals == 1 }
        // A late first arrival would be a second one.
        for _ in 0..<4 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) }

        #expect(arrivals == 1, "the arrival asked for before the rows went landed")
        #expect(icons.loads == 2)
        #expect(Self.pixels(Self.icon(icons, info)) == 40)
        await work.shutdown()
    }

    /// A toolbar action's 512 px PNG decodes on the `.cpu` lane; the button keeps the puzzle piece until it comes,
    /// then shows it at the bar's height.
    @Test func aToolbarIconDecodesOnTheCPULane() async throws {
        let png = try Self.png(side: Self.side)
        let log = LaneLog()
        let work = BackgroundWork(label: "test.extension-button-icon", onRan: { lane, _, _, _ in log.record(lane) })
        let icons = ExtensionActionIcons(work: work, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let button = ExtensionActionButton(actionID: "ext", icons: icons)

        button.update(CEFExtensionAction(id: "ext", name: "Ext", title: "Ext", iconPNG: png))
        let puzzle = try #require(button.image)
        #expect(puzzle.accessibilityDescription == "Ext", "the icon was decoded in the update's turn")
        Self.spin { button.image !== puzzle }

        let icon = try #require(button.image)
        #expect(log.ran == [.cpu])
        #expect(icon !== puzzle)
        #expect(icon.size == NSSize(width: OmnibarStyle.barHeight, height: OmnibarStyle.barHeight))
        #expect(Self.pixels(icon) == Int(CEFExtensionAction.iconPixels), "decoded at the icon's drawn size, not the PNG's 512 px")
        await work.shutdown()
    }

    /// Every tab's toolbar shares the decoded icons (Chrome's `ExtensionActionViewController::GetIcon`): a second
    /// toolbar's button for an action already decoded shows its icon in its first update, with no second decode, and
    /// a new badge (a new PNG) keeps the old icon on the button until the new one is decoded.
    @Test func aSecondToolbarShowsTheDecodedIconInItsFirstUpdate() async throws {
        let (png, badged) = (try Self.png(side: Self.side), try Self.png(side: 256))
        let work = BackgroundWork(label: "test.extension-button-shared")
        let icons = ExtensionActionIcons(work: work, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let action = CEFExtensionAction(id: "ext", name: "Ext", title: "Ext", iconPNG: png)
        let first = ExtensionActionButton(actionID: "ext", icons: icons)
        first.update(action)
        let puzzle = try #require(first.image)
        Self.spin { first.image !== puzzle }
        let decoded = try #require(first.image)

        let second = ExtensionActionButton(actionID: "ext", icons: icons)
        second.update(action)
        #expect(second.image?.accessibilityDescription == nil, "a new tab's button showed the puzzle piece")
        #expect(Self.pixels(try #require(second.image)) == Int(CEFExtensionAction.iconPixels))
        #expect(icons.decodes == 1, "a second toolbar decoded the same icon again")

        var withBadge = action
        withBadge.iconPNG = badged
        withBadge.badge = "3"
        first.update(withBadge)
        #expect(first.image === decoded, "a badge change showed another icon before its decode")
        Self.spin { first.image !== decoded }
        #expect(icons.decodes == 2)
        #expect(first.image?.accessibilityDescription == nil)
        await work.shutdown()
    }

    /// A PNG-only extension's row (no icon file) keeps its icon while a new PNG (a badge change) decodes, then shows
    /// the new one; the cache holds one icon for the extension, not one per PNG (Chrome's `ExtensionIconImage` keeps
    /// the image it has until the new one is loaded, extensions/browser/extension_icon_image.cc).
    @Test func aRowWhosePNGChangesKeepsItsIconUntilTheNewOneArrives() async throws {
        let (png, badged) = (try Self.png(side: 64), try Self.png(side: 96))
        let work = BackgroundWork(label: "test.extension-icons-png")
        let icons = ExtensionIconCache(side: 20, work: work, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        var arrivals = 0
        icons.onLoad = { arrivals += 1 }
        let info = BrowserExtensionInfo(id: "ext", name: "Ext", iconPath: nil)

        _ = icons.images(for: [info], pngs: ["ext": png])
        Self.spin { arrivals == 1 }
        let shown = icons.images(for: [info], pngs: ["ext": png])[0]
        #expect(shown.accessibilityDescription == nil, "the PNG's icon did not arrive")

        let whileDecoding = icons.images(for: [info], pngs: ["ext": badged])[0]
        #expect(whileDecoding === shown, "the row changed to the puzzle piece while its new PNG decoded")
        Self.spin { arrivals == 2 }
        let updated = icons.images(for: [info], pngs: ["ext": badged])[0]
        #expect(updated !== shown)
        #expect(updated.accessibilityDescription == nil)
        #expect(icons.count == 1, "one icon per extension, not one per PNG")
        #expect(icons.images(for: [], pngs: [:]).isEmpty)
        #expect(icons.count == 0, "an extension no longer listed kept its icon")
        await work.shutdown()
    }

    /// An arrival for a PNG the row no longer shows (it changed twice while the first decoded) does not replace the
    /// newer one's.
    @Test func aStaleArrivalIsDropped() async throws {
        let (first, second) = (try Self.png(side: 64), try Self.png(side: 96))
        let work = BackgroundWork(label: "test.extension-icons-stale")
        let icons = ExtensionIconCache(side: 20, work: work, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        var arrivals = 0
        icons.onLoad = { arrivals += 1 }
        let info = BrowserExtensionInfo(id: "ext", name: "Ext", iconPath: nil)

        _ = icons.images(for: [info], pngs: ["ext": first])
        _ = icons.images(for: [info], pngs: ["ext": second])
        Self.spin { arrivals >= 1 && icons.images(for: [info], pngs: ["ext": second])[0].accessibilityDescription == nil }
        for _ in 0..<4 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) }

        #expect(arrivals == 1, "the first PNG's arrival landed after the row moved on")
        #expect(icons.images(for: [info], pngs: ["ext": first])[0].accessibilityDescription == nil,
                "the first PNG is asked for again and the row keeps the second's icon meanwhile")
        await work.shutdown()
    }

    /// ``IconAssetDecode`` returns a bitmap already decoded at the target size, of the named types only.
    @Test nonisolated func theDecoderDecodesAtTheTargetSize() throws {
        let png = try Self.png(side: Self.side)
        let bitmap = try #require(IconAssetDecode.thumbnail(png, types: IconAssetDecode.bitmapTypes, maxPixelSize: 64))
        #expect(max(bitmap.width, bitmap.height) == 64)
        #expect(IconAssetDecode.thumbnail(png, types: [UTType.jpeg.identifier], maxPixelSize: 64) == nil)
        #expect(IconAssetDecode.thumbnail(Data("not an image".utf8), types: IconAssetDecode.bitmapTypes, maxPixelSize: 64) == nil)
        let image = IconAssetDecode.image(bitmap, points: 16)
        #expect(image.size == NSSize(width: 16, height: 16))
    }
}

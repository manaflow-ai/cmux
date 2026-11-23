import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Foundation
import ImageIO
import Testing
import CmuxNextWakeupsTestSupport

/// The Desktop Wallpaper follows what macOS shows: the screen's Fill, Fit, Stretch or Center, the
/// wallpaper store's choice (an aerial, a rotation's current file, how a dynamic picture moves),
/// and a dynamic picture's frame of the time.
@MainActor @Suite final class DesktopFollowTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-follow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func writePNG(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let context = try #require(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    // MARK: Fit

    @Test func macOSScalingOptionsMapToFits() {
        #expect(BackdropArtFit(imageScaling: 3, allowClipping: true) == .fill, "Fill Screen")
        #expect(BackdropArtFit(imageScaling: 3, allowClipping: nil) == .fill)
        #expect(BackdropArtFit(imageScaling: 3, allowClipping: false) == .fit, "Fit to Screen")
        #expect(BackdropArtFit(imageScaling: 1, allowClipping: true) == .stretch, "Stretch to Fill Screen")
        #expect(BackdropArtFit(imageScaling: 2, allowClipping: false) == .center, "Center")
        #expect(BackdropArtFit(imageScaling: 0, allowClipping: false) == .fit, "shrink-only fits")
        #expect(BackdropArtFit(imageScaling: nil, allowClipping: nil) == .fill, "no options: macOS's default")
        #expect(BackdropArtFit.fit.showsFill && BackdropArtFit.center.showsFill)
        #expect(!BackdropArtFit.fill.showsFill && !BackdropArtFit.stretch.showsFill)
    }

    @Test func eachFitPlacesThePicture() throws {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let wide = CGSize(width: 400, height: 100)
        #expect(BackdropArtFit.fill.rect(of: wide, in: bounds) == CGRect(x: -100, y: 0, width: 400, height: 100))
        #expect(BackdropArtFit.fit.rect(of: wide, in: bounds) == CGRect(x: 0, y: 37.5, width: 200, height: 50))
        #expect(BackdropArtFit.stretch.rect(of: wide, in: bounds) == bounds)
        // Center keeps its own size: 400x100 pixels at 2x are 200x50 points.
        #expect(BackdropArtFit.center.rect(of: wide, in: bounds, pointsPerPixel: 0.5) == CGRect(x: 0, y: 25, width: 200, height: 50))
        #expect(BackdropArtFit.fill.rect(of: .zero, in: bounds) == nil)
        #expect(GlassBackdropRect.aspectFill(wide, in: bounds) == BackdropArtFit.fill.rect(of: wide, in: bounds))
    }

    @Test func theLensRectFollowsTheFit() throws {
        let art = CGRect(x: 0, y: 0, width: 200, height: 100)
        let rect = try #require(GlassBackdropRect(imageSize: CGSize(width: 400, height: 100), artFrame: art, pageFrame: art, zoom: 1, fit: .fit))
        #expect(rect == GlassBackdropRect(x: 0, y: 37.5, width: 200, height: 50), "the page lenses the letterboxed picture, not a filled one")
        let filled = try #require(GlassBackdropRect(imageSize: CGSize(width: 400, height: 100), artFrame: art, pageFrame: art, zoom: 1))
        #expect(filled.width == 400, "every other background still fills")
    }

    // MARK: The wallpaper store's choice

    private func index(_ root: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    private func desktop(provider: String, configuration: [String: Any], files: [String] = []) throws -> [String: Any] {
        let config = try PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0)
        return ["Desktop": ["Content": ["Choices": [["Provider": provider, "Configuration": config,
                                                     "Files": files.map { ["relative": $0] }]]]]]
    }

    @Test func anAerialDesktopNamesItsAsset() throws {
        let asset = "B2FC91ED-6891-4DEB-85A1-268B2B4160B6"
        let data = try index(["AllSpacesAndDisplays": try desktop(provider: "com.apple.wallpaper.choice.aerials", configuration: ["assetID": asset])])
        let choice = try #require(DesktopStoreChoice.read(data, display: nil))
        #expect(choice.isAerial)
        #expect(choice.aerialIDs == [asset])
    }

    @Test func aDisplaysOwnChoiceWinsOverEveryDisplays() throws {
        let display = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
        let data = try index([
            "AllSpacesAndDisplays": try desktop(provider: "com.apple.wallpaper.choice.image", configuration: [:], files: ["file:///tmp/all.png"]),
            "Displays": [display: try desktop(provider: "com.apple.wallpaper.choice.image", configuration: [:], files: ["file:///tmp/own.png"])],
        ])
        #expect(DesktopStoreChoice.read(data, display: display.lowercased())?.files.map(\.lastPathComponent) == ["own.png"])
        #expect(DesktopStoreChoice.read(data, display: "00000000-0000-0000-0000-000000000000")?.files.map(\.lastPathComponent) == ["all.png"])
        #expect(DesktopStoreChoice.read(data, display: nil)?.isAerial == false)
        #expect(DesktopStoreChoice.read(Data("not a plist".utf8), display: nil) == nil)
    }

    @Test func theChoiceSaysHowADynamicPictureMoves() {
        #expect(DesktopStoreChoice(provider: nil, strings: ["x", "Dynamic"]).motion == .time)
        #expect(DesktopStoreChoice(provider: nil, strings: ["automatic"]).motion == .appearance)
        #expect(DesktopStoreChoice(provider: nil, strings: ["Dark"]).motion == .dark)
        #expect(DesktopStoreChoice(provider: nil, strings: ["Sonoma Light"]).motion == nil, "a file name is no mode")
    }

    // MARK: Rotation

    @Test func aRotationShowsTheFileTheStoreNames() throws {
        let rotation = folder.appendingPathComponent("Rotation", isDirectory: true)
        try FileManager.default.createDirectory(at: rotation, withIntermediateDirectories: true)
        let first = try writePNG("a.png", in: rotation), second = try writePNG("b.png", in: rotation)
        let outside = try writePNG("c.png", in: folder)
        #expect(DesktopStoreChoice.shownFiles(in: rotation, named: [outside, second]).map(\.lastPathComponent) == ["b.png"],
                "a file outside the folder is not the rotation's")
        #expect(DesktopStoreChoice.shownFiles(in: rotation, named: []).isEmpty)
        #expect(DesktopPicture(reportedURL: rotation, fillColor: nil, fallbackFolder: folder, named: [outside]).resolvedURL()?
            .resolvingSymlinksInPath().lastPathComponent == "a.png", "none of the folder's own named: the first by name")

        let picture = DesktopPicture(reportedURL: rotation, fillColor: nil, fallbackFolder: folder, named: [second])
        #expect(picture.resolvedURL()?.resolvingSymlinksInPath().lastPathComponent == "b.png")
        // The rotation moving on is a new reading, though macOS reports the same folder.
        let before = DesktopWallpaperWatch.Reading(picture: DesktopPicture(reportedURL: rotation, fillColor: nil, fallbackFolder: folder, named: [first]), dark: false)
        let after = DesktopWallpaperWatch.Reading(picture: picture, dark: false)
        #expect(before != after)
        #expect(before == DesktopWallpaperWatch.Reading(picture: DesktopPicture(reportedURL: rotation, fillColor: nil, fallbackFolder: folder, named: [first]), dark: false))
    }

    @Test func theFitIsPartOfTheReading() throws {
        let file = try writePNG("fit.png", in: folder)
        let filled = DesktopWallpaperWatch.Reading(picture: DesktopPicture(reportedURL: file, fillColor: nil, fallbackFolder: folder), dark: false)
        let fitted = DesktopWallpaperWatch.Reading(picture: DesktopPicture(reportedURL: file, fillColor: nil, fallbackFolder: folder, fit: .fit), dark: false)
        #expect(filled != fitted, "only the fit changed")
        #expect(fitted.shown?.fit == .fit)
        #expect(fitted.shown?.selection(dark: false) == .system(path: file.path))
        let red = DesktopWallpaperWatch.Reading(picture: DesktopPicture(reportedURL: file, fillColor: .red, fallbackFolder: folder, fit: .fit), dark: false)
        #expect(red != fitted && red.shown?.fill.first == 1, "the fill color is part of it too")
    }

    // MARK: Time of day

    @Test func aClockPictureShowsTheFrameOfTheTimeAndWhenItTurns() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let frames = BackdropDynamicFrames(solar: [], clock: [.init(time: 0.25, index: 1), .init(time: 0.75, index: 2)], light: 1, dark: 2)
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 12)))
        let location = BackdropLocation(latitude: 0, longitude: 0)
        let moment = DesktopStoreChoice.frame(of: frames, motion: nil, at: noon, location: location, calendar: calendar)
        #expect(moment.index == 1)
        let turn = try #require(moment.next)
        #expect(abs(turn.timeIntervalSince(noon) - 6 * 3_600) <= 1, "the next frame starts at 18:00")
        #expect(DesktopStoreChoice.frame(of: frames, motion: .appearance, at: noon, location: location, calendar: calendar).index == nil)
        #expect(DesktopStoreChoice.frame(of: frames, motion: .dark, at: noon, location: location, calendar: calendar).index == 2)
        #expect(DesktopStoreChoice.frame(of: nil, motion: .time, at: noon, location: location, calendar: calendar).index == nil, "a still has no frame")
        let appearanceOnly = BackdropDynamicFrames(solar: [], clock: [], light: 0, dark: 1)
        #expect(DesktopStoreChoice.frame(of: appearanceOnly, motion: nil, at: noon, location: location, calendar: calendar).index == nil,
                "a light-and-dark picture follows the appearance")
    }

    @Test func aFrameShowsAsAMoment() {
        let shown = DesktopShown(path: "/tmp/Dynamic.heic", frame: 3)
        #expect(shown.selection(dark: true) == .moment(path: "/tmp/Dynamic.heic", frame: 3, dark: true))
        #expect(DesktopShown(path: "/tmp/aerial.mov").isVideo)
        #expect(DesktopShown(path: "/tmp/a.heic", nextChange: Date()) == DesktopShown(path: "/tmp/a.heic"), "the next turn is not part of equality")
    }

    // MARK: The watch

    /// What a fake desktop watch sees: whether a window shows the desktop, whether the app is
    /// hidden, and how many reads ran.
    private final class Flags {
        var visible = false
        var hidden = false
        var reads = 0
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test(.timeLimit(.minutes(1))) func theFollowReReadRunsOnlyWhileADesktopWindowShows() async throws {
        let file = try writePNG("follow.png", in: folder)
        let picture = DesktopPicture(reportedURL: file, fillColor: nil, fallbackFolder: folder)
        let flags = Flags(), clock = ManualClock()
        let watch = DesktopWallpaperWatch(readScreens: {
            flags.reads += 1
            return .init(main: .init(picture: picture, dark: false))
        }, sample: { _ in nil }, isHidden: { flags.hidden }, showsDesktop: { _ in flags.visible }, clock: clock)
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 64, height: 40), images: BackdropImageStore(desktop: watch),
                                      videos: BackdropVideoPlayers())
        watch.register(view)
        watch.start()
        await watch.refreshed()
        #expect(!watch.followPending, "no window shows the desktop: nothing is re-read")

        flags.visible = true
        watch.desktopIsShown()
        #expect(watch.followPending)
        let before = flags.reads
        try await clock.waitForSleeper()
        clock.advance(by: DesktopWallpaperWatch.followInterval)
        try await until { flags.reads > before && watch.followPending }
        #expect(flags.reads == before + 1, "one re-read per interval")
        #expect(watch.followPending, "the next one is set while the window shows")

        flags.hidden = true
        try await clock.waitForSleeper()
        clock.advance(by: DesktopWallpaperWatch.followInterval)
        try await until { !watch.followPending }
        #expect(!watch.followPending, "hidden: the re-reads stop")
        #expect(flags.reads == before + 1)
        #expect(!watch.frameTurnPending, "a still has no frame to turn")
    }

    @Test func eachScreenShowsItsOwnDesktop() async throws {
        let main = try writePNG("main.png", in: folder), own = try writePNG("own.png", in: folder)
        let screen = NSScreen.screens.first
        let id = screen.flatMap(DesktopWallpaperWatch.displayID) ?? 1
        let reading = { (url: URL) in DesktopWallpaperWatch.Reading(picture: DesktopPicture(reportedURL: url, fillColor: nil, fallbackFolder: self.folder), dark: false) }
        let mainReading = reading(main), ownReading = reading(own)
        let watch = DesktopWallpaperWatch(readScreens: { .init(main: mainReading, screens: [id: ownReading, id &+ 1: mainReading]) },
                                          sample: { _ in nil })
        #expect(watch.shown(on: nil) == nil, "nothing before the first reading")
        await watch.refreshed()
        #expect(watch.shown(on: nil) == mainReading.shown, "no screen: the main screen's")
        if let screen { #expect(watch.shown(on: screen) == ownReading.shown, "a screen shows its own picture") }
    }

    @Test func aDesktopEntryGoesWithTheDesktopButAWindowsOwnPickStays() async throws {
        let file = try writePNG("same.png", in: folder), next = try writePNG("next.png", in: folder)
        let store = BackdropImageStore(maxPixelSize: 64, desktop: DesktopWallpaperWatch(read: { nil }, sample: { _ in nil }))
        let picked = BackdropSelection.system(path: file.path)
        #expect(await store.image(picked) != nil)
        #expect(await store.image(picked, desktop: true) != nil)
        store.forgetDesktopPicture(olderThan: 1)
        #expect(store.cached(picked, desktop: true) == nil, "the desktop moved on: its picture goes")
        #expect(store.cached(picked) != nil, "a window that picked the same file keeps it")

        // A rotation landing while the old picture decodes: the cancelled decode keeps nothing.
        let load = Task { await store.image(.system(path: next.path), desktop: true) }
        // Yields, not sleeps: this turn runs again before the decode's own resumption can.
        for _ in 0..<100 where store.desktopEntries().loads == 0 { await Task.yield() }
        #expect(store.desktopEntries().loads == 1)
        store.forgetDesktopPicture(olderThan: 2)
        load.cancel()
        _ = await load.value
        #expect(store.desktopEntries().images == 0, "no stale desktop picture is left behind")
        #expect(store.cached(picked) != nil)
    }

    @Test func theArtIsPlacedAsTheDesktopSays() throws {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 64, height: 40),
                                      images: BackdropImageStore(desktop: DesktopWallpaperWatch(read: { nil }, sample: { _ in nil })),
                                      videos: BackdropVideoPlayers())
        view.applyArtFit(DesktopShown(path: "/tmp/fit.png", fit: .fit, fill: [1, 0, 0]))
        #expect(view.artView.layer?.contentsGravity == .resizeAspect)
        #expect(view.artView.layerContentsPlacement == .scaleProportionallyToFit)
        #expect(view.videoView.playerLayer.videoGravity == .resizeAspect)
        let fill = try #require(view.artView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
        #expect(fill.redComponent > 0.99 && fill.greenComponent < 0.01, "the fill color letterboxes it")

        view.applyArtFit(DesktopShown(path: "/tmp/stretch.png", fit: .stretch))
        #expect(view.artView.layer?.contentsGravity == .resize)
        #expect(view.artView.layer?.backgroundColor == nil, "a stretched picture shows no fill")

        view.applyArtFit(nil)
        #expect(view.artView.layer?.contentsGravity == .resizeAspectFill, "every other background fills")
        #expect(view.videoView.playerLayer.videoGravity == .resizeAspectFill)
    }
}

import AppKit
import AVFoundation
@testable import CmuxNextDesign
@testable import CmuxNextHome
import Foundation
import Testing

/// A video as the wallpaper (cx-14vdf): the person's own movie, Apple's moving wallpaper or a
/// downloaded aerial loops muted behind the window, plays only while someone can see it and the
/// Mac can afford it, and every window showing one file shares one decoder. Apple's files are
/// read where macOS keeps them; a fake `Desktop Pictures` folder stands in for the Mac's.
@MainActor @Suite(.serialized) struct VideoWallpaperTests {
    /// A two-second 64x36 clip in a fresh folder.
    static func clip(_ name: String = "Waves.mp4") async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-video-wallpaper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try await HomeFixtureMedia.writeVideo(to: url, width: 64, height: 36, frames: 60)
        return url
    }

    struct Harness {
        let window: NSWindow
        let backdrop: WindowMaterialView
        var video: BackdropVideoView { backdrop.videoView }

        /// Closes the window as the app does: the views stay in it.
        func close() {
            window.close()
        }
    }

    /// A window whose backdrop shows `selection`, seen and allowed to move unless told otherwise.
    func make(_ selection: BackdropSelection, players: BackdropVideoPlayers, images: BackdropImageStore = BackdropImageStore(maxPixelSize: 256)) -> Harness {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: frame)
        window.contentView = root
        let backdrop = WindowMaterialView(frame: frame, images: images, videos: players)
        backdrop.videoView.visibleOverride = true
        backdrop.videoView.reduceMotionOverride = false
        backdrop.videoView.lowPowerOverride = false
        root.addSubview(backdrop)
        window.orderFrontRegardless()
        backdrop.apply(WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault), selection: selection), tint: .black)
        return Harness(window: window, backdrop: backdrop)
    }

    @Test func aVideoWallpaperLoopsMutedBehindTheWindowWhileItIsSeen() async throws {
        let clip = try await Self.clip()
        let players = BackdropVideoPlayers()
        let h = make(.file(path: clip.path), players: players)
        defer { h.close() }
        #expect(BackdropSelection.file(path: clip.path).isVideo, "a movie is not taken for a video wallpaper")
        #expect(h.video.url == clip, "the window shows \(String(describing: h.video.url)), not the video")
        #expect(!h.video.isHidden)
        let player = try #require(h.video.playerLayer.player, "no player draws into the window")
        #expect(player.isMuted && player.volume == 0, "the wallpaper plays sound")
        #expect(!player.preventsDisplaySleepDuringVideoPlayback, "the wallpaper keeps the display awake")
        #expect(h.video.isPlaying, "a seen video wallpaper does not play")
        #expect(h.video.playerLayer.videoGravity == .resizeAspectFill, "the video does not fill the window")
        // While it loads, and whenever it is paused, its first frame stands in as the art.
        let poster = await BackdropImageStore(maxPixelSize: 128).image(.file(path: clip.path))
        #expect(poster != nil, "a video wallpaper has no poster frame")
    }

    @Test func aVideoHoldsItsFrameWhenNoOneCanSeeItOrTheMacCannotAffordIt() async throws {
        let clip = try await Self.clip()
        let h = make(.file(path: clip.path), players: BackdropVideoPlayers())
        defer { h.close() }
        #expect(h.video.isPlaying)
        h.video.visibleOverride = false
        #expect(!h.video.isPlaying, "an occluded, minimized or hidden window's video still plays")
        h.video.visibleOverride = true
        #expect(h.video.isPlaying, "the video does not resume when the window is seen again")
        h.video.lowPowerOverride = true
        #expect(!h.video.isPlaying, "the video plays in Low Power Mode")
        h.video.lowPowerOverride = false
        h.video.reduceMotionOverride = true
        #expect(!h.video.isPlaying, "the video loops under Reduce Motion")
        h.video.reduceMotionOverride = false
        #expect(h.video.isPlaying)
        // Back to a still picture: the video and its player go.
        h.backdrop.apply(WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault), selection: .art(.vanGoghStarryNight)), tint: .black)
        #expect(h.video.url == nil && h.video.isHidden && h.video.playerLayer.player == nil, "a still wallpaper keeps the video")
    }

    @Test func windowsShowingOneVideoShareOneDecoderAndAClosedWindowLetsItGo() async throws {
        let clip = try await Self.clip()
        let players = BackdropVideoPlayers()
        let first = make(.file(path: clip.path), players: players)
        let second = make(.file(path: clip.path), players: players)
        #expect(players.count == 1, "two windows decode the same video \(players.count) times")
        #expect(first.video.playerLayer.player === second.video.playerLayer.player)
        // One window that cannot be seen leaves the other playing.
        first.video.visibleOverride = false
        #expect(second.video.isPlaying, "hiding one window paused the video in the other")
        first.close()
        #expect(players.count == 1 && second.video.isPlaying)
        second.close()
        #expect(players.count == 0, "a closed window keeps its video decoder")
    }

    /// A Mac with Apple's moving wallpaper in a light, a dark and a portrait cut, and one downloaded aerial.
    func mac() async throws -> (pictures: URL, aerials: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-moving-wallpapers-\(UUID().uuidString)", isDirectory: true)
        let pictures = root.appendingPathComponent("Desktop Pictures"), aerials = root.appendingPathComponent("Customer")
        let moving = pictures.appendingPathComponent(".wallpapers/Sonoma", isDirectory: true)
        let aerial = aerials.appendingPathComponent("4KSDR240FPS", isDirectory: true)
        for folder in [moving, aerial] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for cut in ["Sonoma Graphic Light Landscape.mov", "Sonoma Graphic Dark Landscape.mov", "Sonoma Graphic Light Portrait.mov"] {
            try await HomeFixtureMedia.writeVideo(to: moving.appendingPathComponent(cut), width: 64, height: 36, frames: 10)
        }
        try await HomeFixtureMedia.writeVideo(to: aerial.appendingPathComponent("A1B2.mov"), width: 64, height: 36, frames: 10)
        try Data(#"{"assets":[{"id":"A1B2","accessibilityLabel":"Tahoe Morning"}]}"#.utf8).write(to: aerials.appendingPathComponent("entries.json"))
        return (pictures, aerials)
    }

    @Test func applesMovingWallpapersAndDownloadedAerialsAreListedAsMovingWallpapers() async throws {
        let mac = try await mac()
        let catalog = BackdropCatalog(systemDirectory: mac.pictures, fileManager: .default, aerials: mac.aerials)
        let moving = catalog.choices.filter { $0.pickerCollection?.id == AppleWallpapers.videoCollection }
        // One tile per moving wallpaper (its light cut; the window picks the cut), none for a portrait cut.
        let light = mac.pictures.appendingPathComponent(".wallpapers/Sonoma/Sonoma Graphic Light Landscape.mov")
        // The temporary folder sits behind /var -> /private/var; compare the files, not the spelling.
        let listed = moving.map { URL(fileURLWithPath: String($0.id.dropFirst("system:".count))).resolvingSymlinksInPath() }
        #expect(listed == [light, mac.aerials.appendingPathComponent("4KSDR240FPS/A1B2.mov")].map { $0.resolvingSymlinksInPath() },
                "Moving wallpapers lists \(moving.map(\.id))")
        #expect(moving.allSatisfy { $0.id.hasPrefix("system:") })
        #expect(moving.allSatisfy { $0.isVideo })
        #expect(moving.first?.title == "Sonoma Graphic")
        #expect(AppleWallpapers(desktopPictures: mac.pictures, aerials: mac.aerials).aerialNames()["A1B2"] == "Tahoe Morning",
                "an aerial is not named as System Settings names it")
        // Every listed choice is a setting value the schema accepts and reads back the same.
        #expect(catalog.choices.allSatisfy { BackdropSelection(id: $0.id) == $0 })
    }

    @Test func applesMovingWallpaperPlaysItsLightOrDarkCutWithTheWindow() async throws {
        let mac = try await mac()
        let light = mac.pictures.appendingPathComponent(".wallpapers/Sonoma/Sonoma Graphic Light Landscape.mov")
        let dark = mac.pictures.appendingPathComponent(".wallpapers/Sonoma/Sonoma Graphic Dark Landscape.mov")
        let selection = BackdropSelection.system(path: light.path)
        #expect(selection.followsAppearance && selection.variantID(dark: true) != selection.variantID(dark: false))
        let h = make(selection, players: BackdropVideoPlayers())
        defer { h.close() }
        h.window.appearance = NSAppearance(named: .aqua)
        #expect(h.video.url?.lastPathComponent == light.lastPathComponent, "in light the window plays \(String(describing: h.video.url))")
        h.window.appearance = NSAppearance(named: .darkAqua)
        #expect(h.video.url?.lastPathComponent == dark.lastPathComponent, "in dark the window plays \(String(describing: h.video.url))")
        #expect(h.video.isPlaying)
    }
}

import AppKit
import AVFoundation
@testable import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextTestSupport
import Foundation
import Testing
import CmuxNextWakeupsTestSupport

/// A video as the wallpaper (cx-14vdf): the person's own movie, Apple's moving wallpaper or a
/// downloaded aerial loops muted behind the window, plays only while someone can see it and the
/// Mac can afford it, and every window showing one file shares one decoder. Apple's files are
/// read where macOS keeps them; a fake `Desktop Pictures` folder stands in for the Mac's.
@MainActor @Suite(.serialized, .closesItsWindows) struct VideoWallpaperTests {
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

    /// Waits up to `seconds` for `condition` (AVFoundation readies items on its own schedule).
    func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// A video no one can see for a minute frees its decoder and frame buffers, and comes back at
    /// the exact frame it held. One held for Low Power Mode or Reduce Motion is still on screen:
    /// it keeps them, so its frame never drops to the poster in front of someone.
    @Test func aVideoNoOneCanSeeGivesBackItsDecoderAndPicksUpWhereItWas() async throws {
        let clip = try await Self.clip()
        let players = BackdropVideoPlayers()
        let h = make(.file(path: clip.path), players: players)
        defer { h.close() }
        let url = try #require(h.video.url)
        let player = try #require(h.video.playerLayer.player as? AVQueuePlayer)
        // AVPlayerLooper queues its items once the asset has loaded, on AVFoundation's schedule.
        #expect(try await eventually { !player.items().isEmpty }, "the looper never queued the video")
        #expect(h.video.isPlaying)
        h.video.lowPowerOverride = true
        #expect(!h.video.isPlaying && h.video.canBeSeen)
        players.releaseIfUnseen(url)
        #expect(!players.isReleased(url) && !player.items().isEmpty, "a paused video someone can see lost its frame")
        h.video.lowPowerOverride = false
        // Held one second in, then hidden and released.
        h.video.visibleOverride = false
        #expect(try await eventually { player.currentItem?.status == .readyToPlay })
        await player.seek(to: CMTime(seconds: 1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        #expect(!h.video.canBeSeen)
        players.releaseIfUnseen(url)
        #expect(players.isReleased(url) && player.items().isEmpty, "a video no one can see keeps its decoder")
        #expect(players.count == 1, "the released player left the shared set")
        // Seen again, held still (Low Power) so a restart from 0 cannot pass by playing up to the
        // mark: the same player, new items, back at the second it held.
        h.video.lowPowerOverride = true
        h.video.visibleOverride = true
        #expect(!players.isReleased(url), "the video does not come back when seen again")
        #expect(try await eventually { !player.items().isEmpty }, "the video came back without its items")
        #expect(h.video.playerLayer.player === player, "the window's layer lost its player")
        #expect(try await eventually { !players.isRestoring(url) }, "the restored item never became ready")
        #expect(try await eventually { player.currentTime().seconds > 0.95 }, "the restored video never sought back")
        let resumed = player.currentTime().seconds
        #expect(!h.video.isPlaying && resumed > 0.95 && resumed < 1.05, "the video came back at \(resumed)s, not at the second it held")
        h.video.lowPowerOverride = false
        #expect(h.video.isPlaying)
    }

    @Test func theDecoderGoesOnlyAMinuteAfterTheLastWindowWentOutOfSight() async throws {
        let clip = try await Self.clip()
        let clock = ManualClock()
        let players = BackdropVideoPlayers(clock: clock)
        let h = make(.file(path: clip.path), players: players)
        defer { h.close() }
        let url = try #require(h.video.url)
        h.video.visibleOverride = false
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(40))
        // Updates while hidden do not push the deadline back.
        h.video.lowPowerOverride = true
        h.video.lowPowerOverride = false
        clock.advance(by: .seconds(15))
        #expect(!players.isReleased(url), "the decoder went before the minute was up")
        clock.advance(by: .seconds(6))
        #expect(try await eventually(2) { players.isReleased(url) }, "the deadline moved with the updates, or never came")
        // Seen again before a new minute: nothing is released.
        h.video.visibleOverride = true
        #expect(!players.isReleased(url))
        clock.advance(by: .seconds(120))
        #expect(!players.isReleased(url), "a video someone can see was released")
    }

    @Test func aVideoRestsWhileOtherWindowsHideNearlyAllOfItsWindow() async throws {
        let clip = try await Self.clip()
        let h = make(.file(path: clip.path), players: BackdropVideoPlayers())
        defer { h.close() }
        let frame = BackdropVideoView.screenFrame(h.window.frame)
        var above: [BackdropCoverage.Window] = []
        h.video.windowsAboveOverride = { above }
        // A browser over all but a 3% sliver: AppKit still calls the window visible.
        let browser = CGRect(x: frame.minX - 50, y: frame.minY - 50, width: frame.width * 0.97 + 50, height: frame.height + 100)
        above = [.init(bounds: browser, owner: "Safari")]
        h.video.sampleCoverage()
        #expect(h.video.isPlaying, "one sample rested the video; a window passing over must not")
        h.video.sampleCoverage()
        #expect(!h.video.isPlaying, "a window hidden but for a sliver still decodes its video")
        // Half of it shows again: the video resumes after two samples agree.
        above = [.init(bounds: CGRect(x: browser.minX, y: browser.minY, width: frame.width / 2 + 50, height: browser.height), owner: "Safari")]
        h.video.sampleCoverage()
        h.video.sampleCoverage()
        #expect(h.video.isPlaying, "the video does not resume once the window shows again")
        // A translucent window or the Dock over it hides nothing.
        above = [.init(bounds: browser, alpha: 0.9, owner: "Terminal"), .init(bounds: browser, owner: "Dock")]
        h.video.sampleCoverage()
        h.video.sampleCoverage()
        #expect(h.video.isPlaying, "a translucent window or the Dock rested the video")
    }

    /// The window's own overlay panel (a clear, full-size child window over any browser page or
    /// toast) and floating windows hide nothing, and a window brought to the front plays at once.
    @Test func theWindowsOwnPanelsAndFloatingWindowsNeverRestTheVideo() async throws {
        let clip = try await Self.clip()
        let h = make(.file(path: clip.path), players: BackdropVideoPlayers())
        defer { h.close() }
        let panel = NSPanel(contentRect: h.window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        h.window.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
        defer { h.window.removeChildWindow(panel); panel.close() }
        let frame = BackdropVideoView.screenFrame(h.window.frame)
        var above: [BackdropCoverage.Window] = []
        h.video.windowsAboveOverride = { above }
        // The window server numbers windows only on a host with a display; elsewhere the panel stays
        // unnumbered, and the browser below must still rest the video past it.
        if panel.windowNumber > 0 {
            above = [.init(bounds: frame, number: panel.windowNumber)]
            h.video.sampleCoverage()
            h.video.sampleCoverage()
            #expect(h.video.isPlaying, "the window's own overlay panel rested its video")
        }
        above = [.init(bounds: frame, layer: Int(CGWindowLevelForKey(.floatingWindow)))]
        h.video.sampleCoverage()
        h.video.sampleCoverage()
        #expect(h.video.isPlaying, "a floating window rested the video")
        above = [.init(bounds: frame, owner: "Safari")]
        h.video.sampleCoverage()
        h.video.sampleCoverage()
        try #require(!h.video.isPlaying, "a browser over the whole window did not rest the video")
        h.window.becomeMain()
        #expect(h.video.isPlaying, "a window brought to the front waits for coverage samples to play")
    }

    @Test func turningAnimationsOffHoldsTheVideoAtOnce() async throws {
        let clip = try await Self.clip()
        let h = make(.file(path: clip.path), players: BackdropVideoPlayers())
        let speed = DesignSettings.shared.animationSpeed
        defer {
            DesignSettings.shared.animationSpeed = speed
            h.close()
        }
        // The system's Reduce Motion stays pinned off; only ui.animationSpeed changes.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        h.video.reduceMotionOverride = nil
        DesignSettings.shared.animationSpeed = .fast
        #expect(h.video.isPlaying)
        DesignSettings.shared.animationSpeed = .off
        #expect(!h.video.isPlaying, "the video loops on after animations were turned off")
        DesignSettings.shared.animationSpeed = .normal
        #expect(h.video.isPlaying, "the video stays still after animations were turned back on")
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

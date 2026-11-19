import AppKit
import CmuxNextDesignTokens
@testable import CmuxNextDesign
import CmuxNextTestSupport
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
import WebKit

/// YouTube wallpapers (Leo: "yeah add youtube backgrounds too"): the canonical id, the poster and
/// player size, and the players: one plays app-wide, in the frontmost window that could play it,
/// and one no window can see is unloaded after the video wallpaper's minute.
@MainActor @Suite(.serialized) struct YouTubeWallpaperTests {
    @Test func theCanonicalIDRoundTrips() throws {
        for id in ["youtube:dQw4w9WgXcQ", "youtube:dQw4w9WgXcQ?start=30", "youtube:dQw4w9WgXcQ?end=90",
                   "youtube:aqz-KE-bpKQ?start=30&end=90&quality=720", "youtube:_-_-_-_-_-_?quality=2160",
                   "youtube:dQw4w9WgXcQ?start=86399&end=86400"] {
            let video = try #require(BackdropYouTube(id: id), "\(id) does not parse")
            #expect(video.id == id)
            #expect(BackdropSelection(id: id) == .youtube(video))
            #expect(BackdropSelection.youtube(video).id == id)
        }
        let video = try #require(BackdropYouTube(videoID: "dQw4w9WgXcQ", start: 0, end: nil, quality: 1080))
        #expect(video.id == "youtube:dQw4w9WgXcQ", "defaults are printed")
    }

    @Test func onlyTheCanonicalSpellingIsAnID() {
        for id in ["youtube:dQw4w9WgXc", "youtube:dQw4w9WgXcQQ", "youtube:dQw4w9WgXc!", "youtube:",
                   "youtube:dQw4w9WgXcQ?start=0", "youtube:dQw4w9WgXcQ?quality=1080", "youtube:dQw4w9WgXcQ?end=30&start=10",
                   "youtube:dQw4w9WgXcQ?start=10&start=20", "youtube:dQw4w9WgXcQ?start=60&end=30", "youtube:dQw4w9WgXcQ?end=86401",
                   "youtube:dQw4w9WgXcQ?quality=999", "youtube:dQw4w9WgXcQ?start=010", "youtube:dQw4w9WgXcQ?start=-1",
                   "youtube:dQw4w9WgXcQ?t=30", "youtube:dQw4w9WgXcQ?", "youtube:dQw4w9WgXcQ|youtube:aqz-KE-bpKQ",
                   "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "YouTube:dQw4w9WgXcQ"] {
            #expect(BackdropYouTube(id: id) == nil, "\(id) parsed")
        }
    }

    @Test func aYouTubeChoiceIsAMovingWallpaperWithItsPoster() throws {
        let video = try #require(BackdropYouTube(id: "youtube:dQw4w9WgXcQ"))
        let choice = BackdropSelection.youtube(video)
        #expect(choice.pickerCollection?.id == AppleWallpapers.videoCollection)
        #expect(choice.pickerCollection?.title == "Moving wallpapers")
        #expect(choice.isMovingPicture && !choice.isVideo && choice.shader == nil && !choice.followsAppearance)
        #expect(choice.attribution(title: "A Title") == "YouTube · A Title")
        #expect(choice.title == "dQw4w9WgXcQ", "an untitled video shows its id")
        #expect(choice.thumbnailURL == video.posterURL && choice.imageURL == video.posterURL)
        #expect(video.posterURL.lastPathComponent == "dQw4w9WgXcQ.jpg")
        #expect(video.posterRemoteURL?.absoluteString == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        #expect(choice.sourceURL?.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    @Test func thePlayerIsLaidOutAtItsQualityAndFillsTheWindow() throws {
        let video = try #require(BackdropYouTube(videoID: "dQw4w9WgXcQ", quality: 720))
        #expect(video.playerSize(backingScale: 2) == CGSize(width: 640, height: 360))
        #expect(try #require(BackdropYouTube(videoID: "dQw4w9WgXcQ")).playerSize(backingScale: 1) == CGSize(width: 1920, height: 1080))
        // A tall window: the player is scaled up to its height, cropped at the sides.
        let tall = BackdropYouTubeView.geometry(view: CGSize(width: 800, height: 900), player: CGSize(width: 640, height: 360))
        #expect(abs(tall.hostBounds.height - 360) < 0.001)
        #expect(tall.playerFrame.size == CGSize(width: 640, height: 360))
        #expect(tall.playerFrame.minX < 0 && abs(tall.playerFrame.midX - tall.hostBounds.width / 2) < 0.001)
        // A wide one: scaled to its width, cropped top and bottom.
        let wide = BackdropYouTubeView.geometry(view: CGSize(width: 3000, height: 1000), player: CGSize(width: 640, height: 360))
        #expect(abs(wide.hostBounds.width - 640) < 0.001 && wide.playerFrame.minY < 0)
    }

    @Test func thePageLoopsMutedWithoutControlsInTheNocookieEmbed() throws {
        let video = try #require(BackdropYouTube(id: "youtube:dQw4w9WgXcQ?start=30&end=90"))
        let page = BackdropYouTubePlayer.page(video, startAt: 42)
        for part in ["www.youtube-nocookie.com", "mute:1", "controls:0", "disablekb:1", "fs:0", "rel:0", "iv_load_policy:3",
                     "playsinline:1", "enablejsapi:1", "autoplay:0", "start:42", "loopStart=30", "loopEnd=90",
                     "videoId:'dQw4w9WgXcQ'", "YT.PlayerState.ENDED", "origin:'https://cmux.com'"] {
            #expect(page.contains(part), "the page lacks \(part)")
        }
    }

    // MARK: The players

    @MainActor final class FakePlayer: BackdropYouTubePlaying {
        let video: BackdropYouTube
        let resumeAt: Int?
        let view = NSView()
        var hasPlayed = false
        var position = 0
        var onEvent: (@MainActor (BackdropYouTubePlayerEvent) -> Void)?
        var playing = false
        var closed = false

        init(video: BackdropYouTube, resumeAt: Int?) {
            self.video = video
            self.resumeAt = resumeAt
        }

        func play() { playing = true }
        func pause() { playing = false }
        func close() { closed = true }
    }

    final class Made {
        var players: [FakePlayer] = []
    }

    static func players(clock: ManualClock, order: [Int], made: Made) -> BackdropYouTubePlayers {
        BackdropYouTubePlayers(clock: clock, order: { order }) { video, resumeAt in
            let player = FakePlayer(video: video, resumeAt: resumeAt)
            made.players.append(player)
            return player
        }
    }

    static func view(_ players: BackdropYouTubePlayers) -> BackdropYouTubeView {
        BackdropYouTubeView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), players: players,
                            idle: BackdropIdle(sinceInput: { 0 }, settings: nil, pauseAfter: { 300 }, monitorsInput: false))
    }

    @Test func oneWindowPlaysAndItIsTheFrontmostThatCould() throws {
        let made = Made()
        let players = Self.players(clock: ManualClock(), order: [2, 1, 3], made: made)
        let video = try #require(BackdropYouTube(videoID: "dQw4w9WgXcQ"))
        let other = try #require(BackdropYouTube(videoID: "aqz-KE-bpKQ"))
        let back = Self.view(players), front = Self.view(players), third = Self.view(players)
        players.report(back, video: video, window: 1, eligible: true, seen: true)
        #expect(players.isChosen(back) && made.players.count == 1 && made.players[0].playing)
        #expect(made.players[0].view.superview === back.playerHost)
        // A window in front shows the same video: the one player moves there, no second stream.
        players.report(front, video: video, window: 2, eligible: true, seen: true)
        #expect(players.isChosen(front) && made.players.count == 1 && made.players[0].playing)
        #expect(made.players[0].view.superview === front.playerHost && back.playerHost.subviews.isEmpty)
        // The front window can no longer play (idle, covered past half, too small): the next one does.
        players.report(front, video: video, window: 2, eligible: false, seen: true)
        #expect(players.isChosen(back) && made.players[0].view.superview === back.playerHost && made.players[0].playing)
        // Another video in a third window behind: it waits; one player plays app-wide.
        players.report(third, video: other, window: 3, eligible: true, seen: true)
        #expect(players.isChosen(back) && made.players.count == 1)
        players.report(back, video: video, window: 1, eligible: false, seen: true)
        #expect(players.isChosen(third) && made.players.count == 2)
        #expect(made.players[1].playing && !made.players[0].playing, "two YouTube players play at once")
        // No window could play: nothing plays, nothing is chosen.
        players.report(third, video: other, window: 3, eligible: false, seen: true)
        #expect(players.chosen == nil && made.players.allSatisfy { !$0.playing })
    }

    @Test(.timeLimit(.minutes(1))) func aPlayerNoOneCanSeeIsUnloadedAfterAMinuteAndPicksUpWhereItWas() async throws {
        let clock = ManualClock()
        let made = Made()
        let players = Self.players(clock: clock, order: [1], made: made)
        let video = try #require(BackdropYouTube(videoID: "dQw4w9WgXcQ"))
        let view = Self.view(players)
        players.report(view, video: video, window: 1, eligible: true, seen: true)
        let first = try #require(made.players.first)
        first.position = 73
        // Covered or hidden: it holds, and the minute starts.
        players.report(view, video: video, window: 1, eligible: false, seen: false)
        #expect(!first.playing && !first.closed && players.loadedCount == 1)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(59))
        #expect(!first.closed, "unloaded before the minute")
        clock.advance(by: .seconds(1))
        for _ in 0..<250 where !first.closed { try await Task.sleep(for: .milliseconds(4)) }
        #expect(first.closed && players.loadedCount == 0)
        #expect(view.playerHost.subviews.isEmpty, "the unloaded player stays in the window")
        // Seen and chosen again: a new player at the second it held.
        players.report(view, video: video, window: 1, eligible: true, seen: true)
        #expect(made.players.count == 2 && made.players[1].resumeAt == 73 && made.players[1].playing)
    }

    @Test func aWindowSeenAgainBeforeTheMinuteKeepsItsPlayer() async throws {
        let clock = ManualClock()
        let made = Made()
        let players = Self.players(clock: clock, order: [1], made: made)
        let video = try #require(BackdropYouTube(videoID: "dQw4w9WgXcQ"))
        let view = Self.view(players)
        players.report(view, video: video, window: 1, eligible: true, seen: true)
        players.report(view, video: video, window: 1, eligible: false, seen: false)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(30))
        // Held for Low Power Mode, but seen: it keeps the player and its frame.
        players.report(view, video: video, window: 1, eligible: false, seen: true)
        clock.advance(by: .seconds(60))
        #expect(made.players.count == 1 && !made.players[0].closed)
        // The window leaves (closed): unloaded at once.
        players.leave(view)
        #expect(made.players[0].closed && players.loadedCount == 0)
    }

    @Test func aVideoTheEmbedRefusesKeepsItsPoster() throws {
        let made = Made()
        let players = Self.players(clock: ManualClock(), order: [1], made: made)
        let video = try #require(BackdropYouTube(videoID: "dQw4w9WgXcQ"))
        let view = Self.view(players)
        players.report(view, video: video, window: 1, eligible: true, seen: true)
        made.players[0].onEvent?(.failed(code: 150))
        #expect(made.players[0].closed && players.failed(video))
        players.report(view, video: video, window: 1, eligible: true, seen: true)
        #expect(made.players.count == 1, "a refused video is loaded again")
    }

    // MARK: Off (BackdropYouTube.isOffered)

    static func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    @Test func offAYouTubeIDMakesNoWebViewAndDrawsNoPicture() async throws {
        #expect(!BackdropYouTube.isOffered, "YouTube wallpapers ship off until Leo decides")
        _ = NSApplication.shared
        let video = try #require(BackdropYouTube(id: "youtube:dQw4w9WgXcQ"))
        let frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let images = BackdropImageStore(maxPixelSize: 256)
        #expect(!images.offersYouTube)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let backdrop = WindowMaterialView(frame: frame, images: images)
        window.contentView = backdrop
        window.orderFrontRegardless()
        backdrop.apply(WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault), selection: .youtube(video)), tint: .black)
        await backdrop.artLoad?.value
        #expect(backdrop.youtubeView == nil && !backdrop.showsYouTube)
        #expect(!Self.descendants(backdrop).contains { $0 is WKWebView }, "a web view was made while YouTube is off")
        #expect(backdrop.artView.isHidden, "a picture was drawn for a YouTube id while YouTube is off")
        #expect(await images.image(.youtube(video)) == nil && images.youtube.loadedCount == 0)
        #expect(await images.thumbnailURL(of: .youtube(video)) == nil)
        // On (tests only): the one view is made.
        let on = WindowMaterialView(frame: frame, images: BackdropImageStore(maxPixelSize: 256, offersYouTube: true))
        #expect(on.youtubeView?.superview === on)
    }
}

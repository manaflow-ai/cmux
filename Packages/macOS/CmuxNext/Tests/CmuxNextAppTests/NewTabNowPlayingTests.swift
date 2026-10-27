@testable import CmuxNextAgentPane
@testable import CmuxNextNowPlaying
import CmuxNextSettings
import CmuxNextSidebar
import CoreGraphics
import Foundation
import ImageIO
import Observation
import Testing
import UniformTypeIdentifiers

/// The New Tab page's Now Playing player, host side: the page's controls and its menu's items
/// decode to commands and reach the App's handler (anything else is refused), the transport runs on
/// the source while Open in, Hide, Undo and Settings… go to the App's page actions, the track goes
/// to the page as the JSON newtab/nowPlaying.ts reads (with the app that plays), the card's track
/// maps onto it with its artwork as a data URL, and `tabs.newTabNowPlaying` off sends the page nil
/// while the sidebar card keeps playing.
@MainActor @Suite(.serialized) struct NewTabNowPlayingTests {
    static func request(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "nowPlaying.command", "params": params])
    }

    @Test func thePagesControlsDecode() {
        #expect(Self.request(["command": "playPause"]) == .nowPlaying(.playPause))
        #expect(Self.request(["command": "previous"]) == .nowPlaying(.previous))
        #expect(Self.request(["command": "next"]) == .nowPlaying(.next))
        #expect(Self.request(["command": "seek", "seconds": 90.5]) == .nowPlaying(.seek(90.5)))
        #expect(Self.request(["command": "open"]) == .nowPlaying(.open))
        #expect(Self.request(["command": "hide"]) == .nowPlaying(.show(false)))
        #expect(Self.request(["command": "show"]) == .nowPlaying(.show(true)))
        #expect(Self.request(["command": "settings"]) == .nowPlaying(.settings))
        for bad: [String: Any] in [[:], ["command": "stop"], ["command": "seek"], ["command": "seek", "seconds": -1], ["command": "Hide"]] {
            #expect(Self.request(bad) == .unsupported("nowPlaying.command"), "\(bad) decoded")
        }
        #expect(AgentPageOps.methods["nowPlaying.command"] == "nowPlaying.command", "the page host refuses the op")
    }

    @Test func aControlReachesTheAppOnlyOnceWired() {
        let player = AgentPaneNowPlaying.shared
        let saved = player.onCommand
        defer { player.onCommand = saved }
        player.onCommand = nil
        #expect(!player.perform(.next), "an unwired player took the control")
        var got: [AgentPaneNowPlaying.Command] = []
        player.onCommand = { got.append($0) }
        #expect(player.perform(.playPause) && player.perform(.seek(3)))
        #expect(got == [.playPause, .seek(3)])
        #expect(NewTabNowPlaying.sidebarCommand(.seek(3)) == .seek(3) && NewTabNowPlaying.sidebarCommand(.next) == .next)
        for item: AgentPaneNowPlaying.Command in [.open, .show(false), .show(true), .settings] {
            #expect(NewTabNowPlaying.sidebarCommand(item) == nil, "\(item) reached the source as a transport control")
        }
    }

    @Observable final class FakeSource: NowPlayingSource {
        var nowPlaying: SidebarNowPlaying?
        @ObservationIgnored var commands: [SidebarNowPlayingCommand] = []
        func perform(_ command: SidebarNowPlayingCommand) { commands.append(command) }
    }

    @Observable final class Flag {
        var on: Bool
        init(_ on: Bool) { self.on = on }
    }

    static let labels = SidebarNowPlaying.Labels(play: "Play", pause: "Pause", previous: "Previous Track", next: "Next Track")
    static let spotify = SidebarNowPlaying.App(bundleIdentifier: "com.spotify.client", name: "Spotify")

    static func shown(app: SidebarNowPlaying.App? = spotify) -> SidebarNowPlaying {
        SidebarNowPlaying(title: "Weightless", artist: "Marconi Union", isPlaying: true, position: 60, duration: 480,
                          canPrevious: true, canNext: true, labels: labels, app: app)
    }

    /// The menu: the transport runs on the source; Open in, Hide, Undo and Settings… reach the
    /// App's page actions (Open in with the app that plays, and nothing without one).
    @Test func theMenusItemsReachTheSourceAndTheApp() {
        let saved = NewTabNowPlaying.page
        defer { NewTabNowPlaying.page = saved }
        var shown: [Bool] = [], settings = 0, opened: [String] = []
        NewTabNowPlaying.page = NewTabNowPlaying.Page(setShown: { shown.append($0) }, openSettings: { settings += 1 },
                                                      openApp: { opened.append($0) })
        let source = FakeSource()
        source.nowPlaying = Self.shown()
        for command: AgentPaneNowPlaying.Command in [.playPause, .next, .previous, .open, .show(false), .show(true), .settings] {
            NewTabNowPlaying.perform(command, on: source)
        }
        #expect(source.commands == [.playPause, .next, .previous])
        #expect(opened == ["com.spotify.client"])
        #expect(shown == [false, true])
        #expect(settings == 1)
        source.nowPlaying = Self.shown(app: nil)
        NewTabNowPlaying.perform(.open, on: source)
        #expect(opened == ["com.spotify.client"], "Open in ran for cmux's own player")
    }

    /// `tabs.newTabNowPlaying` off: the page gets nil (no player, no space) while the sidebar card
    /// still shows what plays; on again, the page gets the track back. Off before the first push,
    /// the page never gets one.
    @Test func theNewTabSettingHidesOnlyThePagesPlayer() async throws {
        // Its own player: other suites' follows push to the shared one at the same time.
        let player = AgentPaneNowPlaying()
        let source = FakeSource()
        source.nowPlaying = Self.shown()
        let newTab = Flag(false)
        let model = SidebarModel()
        let feed = model.followNowPlaying(source, enabled: { true }, onNewTab: { newTab.on }, player: player)
        defer { feed.cancel() }
        try await Self.until { model.nowPlaying != nil }
        #expect(model.nowPlaying?.title == "Weightless", "the sidebar card lost the track")
        #expect(player.track == nil, "the New Tab page got a player while tabs.newTabNowPlaying is off")
        newTab.on = true
        try await Self.until { player.track != nil }
        #expect(player.track?.title == "Weightless" && player.track?.source == "Spotify")
        newTab.on = false
        try await Self.until { player.track == nil }
        #expect(model.nowPlaying != nil, "hiding the New Tab player hid the sidebar card")
    }

    /// The sidebar card off (its default) and the New Tab player on (its default): the page gets
    /// the track and the source runs; both off, the source stops and nothing is read.
    @Test func theNewTabPlayerShowsWithTheSidebarCardOff() async throws {
        // Its own player: other suites' follows push to the shared one at the same time.
        let player = AgentPaneNowPlaying()
        let source = RunningSource()
        source.nowPlaying = Self.shown()
        let newTab = Flag(true)
        let model = SidebarModel()
        let feed = model.followNowPlaying(source, enabled: { false }, onNewTab: { newTab.on }, player: player)
        defer { feed.cancel() }
        try await Self.until { player.track != nil }
        #expect(player.track?.title == "Weightless")
        #expect(model.nowPlaying == nil, "the sidebar card showed while sidebar.nowPlaying.enabled is off")
        #expect(source.running, "the source does not run for the New Tab player")
        newTab.on = false
        try await Self.until { player.track == nil && !source.running }
    }

    @Observable final class RunningSource: NowPlayingSource {
        var nowPlaying: SidebarNowPlaying?
        @ObservationIgnored var running = false
        func perform(_ command: SidebarNowPlayingCommand) {}
        func run(_ need: NowPlayingNeed) { running = need != .off }
    }

    static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func theTrackGoesToThePageAsItReadsIt() throws {
        let labels = SidebarNowPlaying.Labels(play: "Play", pause: "Pause", previous: "Previous Track", next: "Next Track")
        let shown = SidebarNowPlaying(title: "Weightless", artist: "Marconi Union", artwork: Data([1, 2, 3]), isPlaying: true,
                                      position: 60, duration: 480, rate: 1, positionDate: Date(timeIntervalSince1970: 1_800_000_000),
                                      canPrevious: true, canNext: false, labels: labels,
                                      app: SidebarNowPlaying.App(bundleIdentifier: "com.apple.Music", name: "Music"))
        let track = NewTabNowPlaying.track(shown, artwork: "data:image/png;base64,AQID")
        let event = AgentPageEvent.nowPlaying(track)
        #expect(event.kind == "nowPlaying")
        guard case .object(let json) = event.value else { Issue.record("not an object: \(event.value)"); return }
        #expect(json["title"] == .string("Weightless") && json["artist"] == .string("Marconi Union"))
        #expect(json["playing"] == .bool(true) && json["canNext"] == .bool(false) && json["canPrevious"] == .bool(true))
        #expect(json["position"] == .number(60) && json["duration"] == .number(480) && json["rate"] == .number(1))
        #expect(json["positionDate"] == .number(1_800_000_000_000))
        #expect(json["artwork"] == .string("data:image/png;base64,AQID"))
        #expect(json["source"] == .string("Music"), "the page cannot name the app for Open in")
        var own = shown
        own.app = nil
        guard case .object(let ownJSON) = AgentPageEvent.nowPlaying(NewTabNowPlaying.track(own, artwork: nil)).value else { return }
        #expect(ownJSON["source"] == nil, "cmux's own player named an app")
        #expect(json["labels"] == .object(["play": .string("Play"), "pause": .string("Pause"),
                                           "previous": .string("Previous Track"), "next": .string("Next Track")]))
        #expect(AgentPageEvent.nowPlaying(nil).value == .null, "nothing playing is not null for the page")
    }

    /// cmux's own player hands over the file's embedded art as is (often a multi-MB JPEG); the page
    /// gets it redrawn as a small PNG, since every track change goes to every agent page.
    @Test func largeArtworkReachesThePageAsASmallPNG() throws {
        let side = 1200
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let url = try #require(NewTabNowPlaying.artworkURL(out as Data))
        let prefix = "data:image/png;base64,"
        #expect(url.hasPrefix(prefix))
        let png = try #require(Data(base64Encoded: String(url.dropFirst(prefix.count))))
        let image = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == NewTabNowPlaying.artworkSide && image.height == NewTabNowPlaying.artworkSide)
        #expect(NewTabNowPlaying.artworkURL(Data([1, 2, 3])) == nil, "bytes that are not an image became artwork")
    }
}

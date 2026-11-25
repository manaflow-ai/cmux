import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextNowPlaying
import CmuxNextSidebar
import Foundation
import Observation
import Testing

/// Other apps on the Now Playing card (Spotify, Music), read from macOS Now Playing through the
/// MediaRemote adapter's JSON lines: full and diff payloads, cmux's own entries left out, the
/// controls sent back as adapter commands, and the order among the card's sources.
@MainActor @Suite struct SystemNowPlayingTests {
    final class FakeAdapter: SystemNowPlayingAdapter {
        var onUpdate: (@MainActor (SystemNowPlayingFeed.Update) -> Void)?
        var starts = 0, stops = 0
        var sent: [SystemNowPlayingCommand] = []
        func start(onUpdate: @escaping @MainActor (SystemNowPlayingFeed.Update) -> Void) { starts += 1; self.onUpdate = onUpdate }
        func stop() { stops += 1; onUpdate = nil }
        func send(_ command: SystemNowPlayingCommand) { sent.append(command) }
        func emit(diff: Bool, _ payload: [String: Any]) {
            let line = try! JSONSerialization.data(withJSONObject: ["type": "data", "diff": diff, "payload": payload])
            if let update = SystemNowPlayingFeed.Update.decode(line) { onUpdate?(update) }
        }
    }

    @Observable final class FakeSource: NowPlayingSource {
        var nowPlaying: SidebarNowPlaying?
        @ObservationIgnored var commands: [SidebarNowPlayingCommand] = []
        func perform(_ command: SidebarNowPlayingCommand) { commands.append(command) }
    }

    static let labels = SidebarNowPlaying.Labels(play: "Play", pause: "Pause", previous: "Previous Track", next: "Next Track")
    static let spotify: [String: Any] = [
        "bundleIdentifier": "com.spotify.client", "title": "Weightless", "artist": "Marconi Union", "album": "Weightless",
        "playing": true, "durationMicros": 480_000_000, "elapsedTimeMicros": 60_000_000,
        "timestampEpochMicros": 1_800_000_000_000_000, "playbackRate": 1,
    ]

    static func line(diff: Bool, _ payload: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["type": "data", "diff": diff, "payload": payload])
    }

    @Test func aFullPayloadIsWhatPlays() throws {
        var feed = SystemNowPlayingFeed()
        let applied = feed.apply(Self.line(diff: false, Self.spotify))
        #expect(applied)
        let report = try #require(feed.report)
        #expect(report.bundleIdentifier == "com.spotify.client" && report.title == "Weightless" && report.artist == "Marconi Union")
        #expect(report.isPlaying && report.duration == 480 && report.elapsed == 60 && report.rate == 1)
        #expect(report.timestamp == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func aDiffUpdatesAndANullRemoves() throws {
        var feed = SystemNowPlayingFeed()
        feed.apply(Self.line(diff: false, Self.spotify))
        feed.apply(Self.line(diff: true, ["playing": false, "artist": NSNull(), "elapsedTimeMicros": 90_000_000]))
        let report = try #require(feed.report)
        #expect(report.title == "Weightless", "a diff dropped the keys it did not name")
        #expect(!report.isPlaying && report.elapsed == 90 && report.artist.isEmpty)
        // A full payload with no keys: nothing plays.
        feed.apply(Self.line(diff: false, [:]))
        #expect(feed.report == nil)
    }

    @Test func otherLinesChangeNothing() {
        var feed = SystemNowPlayingFeed()
        feed.apply(Self.line(diff: false, Self.spotify))
        let before = feed
        let notJSON = feed.apply(Data("not json".utf8))
        let notData = feed.apply(Data(#"{"type":"error","payload":{}}"#.utf8))
        #expect(!notJSON && !notData)
        #expect(feed == before)
    }

    @Test func linesSplitAcrossChunks() {
        let splitter = AdapterLineSplitter()
        #expect(splitter.append(Data("{\"a\":".utf8)).isEmpty)
        let lines = splitter.append(Data("1}\n{\"b\":2}\n{\"c\"".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"b":2}"#])
    }

    /// The stream never outlives cmux: its watch shell ends the adapter once the pipe cmux holds on
    /// its stdin closes, which the kernel does however cmux exits.
    @Test func theStreamEndsWhenCmuxsEndOfThePipeCloses() async throws {
        // A stand-in adapter that says its pid and then runs for ten minutes.
        let (shell, arguments) = MediaRemoteAdapterProcess.watched(URL(fileURLWithPath: "/bin/sh"),
                                                                   ["-c", "echo $$; exec /bin/sleep 600"])
        let process = Process()
        process.executableURL = shell
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let line = try #require(String(data: stdout.fileHandleForReading.availableData, encoding: .utf8))
        let child = try #require(pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(kill(child, 0) == 0, "the adapter did not start")
        #expect(process.isRunning, "the watch shell ended while cmux holds the pipe")
        // cmux exits: its end of the pipe closes.
        try stdin.fileHandleForWriting.close()
        try await Self.until { kill(child, 0) != 0 && !process.isRunning }
        #expect(kill(child, 0) != 0, "the adapter outlived cmux's end of the pipe")
        #expect(!process.isRunning, "the watch shell outlived the adapter")
    }

    @Test func commandsAreTheAdaptersArguments() {
        #expect(SystemNowPlayingCommand.togglePlayPause.arguments == ["send", "2"])
        #expect(SystemNowPlayingCommand.next.arguments == ["send", "4"])
        #expect(SystemNowPlayingCommand.previous.arguments == ["send", "5"])
        #expect(SystemNowPlayingCommand.seek(61.5).arguments == ["seek", "61500000"])
        #expect(SystemNowPlayingCommand.seek(-3).arguments == ["seek", "0"])
    }

    @Test func anotherAppIsOnTheCardAndItsControlsGoBack() throws {
        let adapter = FakeAdapter()
        let source = SystemNowPlaying(adapter: adapter, ignoring: ["com.cmux.next"], labels: Self.labels)
        source.run(true)
        source.run(true)
        #expect(adapter.starts == 1, "running twice started two streams")
        adapter.emit(diff: false, Self.spotify)
        let shown = try #require(source.nowPlaying)
        #expect(shown.title == "Weightless" && shown.artist == "Marconi Union" && shown.isPlaying && shown.canSeek)
        #expect(shown.position(at: Date(timeIntervalSince1970: 1_800_000_010)) == 70, "the position does not move on from the report")
        source.perform(.playPause)
        source.perform(.next)
        source.perform(.previous)
        source.perform(.seek(30))
        #expect(adapter.sent == [.togglePlayPause, .next, .previous, .seek(30)])
        source.run(false)
        #expect(adapter.stops == 1 && source.nowPlaying == nil, "stopping kept the last track")
        adapter.emit(diff: false, Self.spotify)
        #expect(source.nowPlaying == nil, "a line after stopping showed")
    }

    @Observable final class Flag {
        var on: Bool
        init(_ on: Bool) { self.on = on }
    }

    /// Waits for `condition`, up to two seconds.
    static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func theAdapterRunsOnlyWhileTheCardIsOn() async throws {
        let adapter = FakeAdapter()
        let system = SystemNowPlaying(adapter: adapter, ignoring: [], labels: Self.labels)
        let sources = NowPlayingSources(player: MusicPlayer(labels: Self.labels), tabs: FakeSource(), system: system, otherApps: { true })
        let model = SidebarModel()
        let flag = Flag(false)
        let feed = model.followNowPlaying(sources, enabled: { flag.on })
        defer { feed.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(adapter.starts == 0, "the adapter streams while Now Playing is off")
        flag.on = true
        try await Self.until { adapter.starts == 1 }
        #expect(adapter.starts == 1, "turning Now Playing on with nothing playing started no stream")
        adapter.emit(diff: false, Self.spotify)
        try await Self.until { model.nowPlaying?.title == "Weightless" }
        #expect(model.nowPlaying?.title == "Weightless", "another app's track is not on the card")
        flag.on = false
        try await Self.until { adapter.stops == 1 }
        #expect(adapter.stops == 1 && model.nowPlaying == nil, "turning Now Playing off kept the stream or the card")
    }

    @Test func cmuxsOwnEntriesAreLeftOut() {
        let adapter = FakeAdapter()
        let source = SystemNowPlaying(adapter: adapter, ignoring: ["com.cmux.next"], labels: Self.labels)
        source.run(true)
        var own = Self.spotify
        own["bundleIdentifier"] = "com.cmux.next"
        adapter.emit(diff: false, own)
        #expect(source.nowPlaying == nil, "cmux's own Now Playing came back as another app")
        own["bundleIdentifier"] = "com.apple.WebKit.GPU"
        own["parentApplicationBundleIdentifier"] = "com.cmux.next"
        adapter.emit(diff: false, own)
        #expect(source.nowPlaying == nil, "a cmux WebKit tab came back as another app")
        source.perform(.playPause)
        #expect(adapter.sent.isEmpty, "a control went to cmux's own entry")
    }

    @Test func theArtworkIsASmallPNG() async throws {
        let adapter = FakeAdapter()
        let source = SystemNowPlaying(adapter: adapter, ignoring: [], labels: Self.labels)
        source.run(true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 600, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        var payload = Self.spotify
        payload["artworkData"] = jpeg.base64EncodedString()
        payload["artworkMimeType"] = "image/jpeg"
        adapter.emit(diff: false, payload)
        // Decoded and drawn off the main actor: the track shows at once, its artwork once ready.
        #expect(source.nowPlaying?.title == "Weightless")
        try await Self.until { source.nowPlaying?.artwork != nil }
        let png = try #require(source.nowPlaying?.artwork)
        let image = try #require(NSBitmapImageRep(data: png))
        #expect(image.pixelsWide == 320 && image.pixelsHigh == 320)
    }

    @Test func aPlayingAppTakesTheCardOnlyFromWhatIsPaused() {
        let player = MusicPlayer(labels: Self.labels)
        let tab = FakeSource(), system = FakeSource()
        let sources = NowPlayingSources(player: player, tabs: tab, system: system, otherApps: { true })
        system.nowPlaying = SidebarNowPlaying(title: "Spotify", isPlaying: false, labels: Self.labels)
        #expect(sources.nowPlaying?.title == "Spotify")
        tab.nowPlaying = SidebarNowPlaying(title: "Video", isPlaying: false, labels: Self.labels)
        #expect(sources.nowPlaying?.title == "Video", "a paused app came before a paused tab")
        system.nowPlaying?.isPlaying = true
        #expect(sources.nowPlaying?.title == "Spotify", "a playing app stayed behind a paused tab")
        sources.perform(.next)
        #expect(system.commands == [.next] && tab.commands.isEmpty, "the control did not reach the app on the card")
        tab.nowPlaying?.isPlaying = true
        #expect(sources.nowPlaying?.title == "Video", "a playing tab came after another app")
        #expect(NowPlayingSources.pick([nil, nil, nil]) == nil)
    }

    /// u8394: the player showed the user's other browser's audio (macOS Now Playing). By default
    /// (`sidebar.nowPlaying.otherApps` off) only what plays in cmux shows: another app's track
    /// never reaches the card or the New Tab page and a control never goes to it.
    @Test func anotherAppIsLeftOutWhileOtherAppsIsOff() {
        let tab = FakeSource(), system = FakeSource()
        system.nowPlaying = SidebarNowPlaying(title: "A Chrome video", isPlaying: true, labels: Self.labels)
        let byDefault = NowPlayingSources(player: MusicPlayer(labels: Self.labels), tabs: tab, system: system)
        #expect(byDefault.nowPlaying == nil, "another browser's audio is on the card by default")
        byDefault.perform(.playPause)
        #expect(system.commands.isEmpty, "a control went to another app by default")
        tab.nowPlaying = SidebarNowPlaying(title: "A cmux tab", isPlaying: false, labels: Self.labels)
        #expect(byDefault.nowPlaying?.title == "A cmux tab", "a paused cmux tab lost to another app that plays")
        let on = NowPlayingSources(player: MusicPlayer(labels: Self.labels), tabs: FakeSource(), system: system, otherApps: { true })
        #expect(on.nowPlaying?.title == "A Chrome video", "other apps on, and another app's track is not on the card")
    }

    /// With other apps off macOS Now Playing is not read at all, card and New Tab player on or
    /// not; turning the setting on starts the stream and the track shows on both, off stops it.
    @Test func macOSNowPlayingStreamsOnlyWhileOtherAppsIsOn() async throws {
        let adapter = FakeAdapter()
        let system = SystemNowPlaying(adapter: adapter, ignoring: [], labels: Self.labels)
        let otherApps = Flag(false)
        let sources = NowPlayingSources(player: MusicPlayer(labels: Self.labels), tabs: FakeSource(), system: system,
                                        otherApps: { otherApps.on })
        let model = SidebarModel()
        let page = AgentPaneNowPlaying()
        let feed = model.followNowPlaying(sources, enabled: { true }, onNewTab: { true }, player: page)
        defer { feed.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(adapter.starts == 0, "macOS Now Playing was read while other apps are off")
        #expect(model.nowPlaying == nil && page.track == nil)
        otherApps.on = true
        try await Self.until { adapter.starts == 1 }
        #expect(adapter.starts == 1, "turning other apps on did not read macOS Now Playing")
        var chrome = Self.spotify
        chrome["bundleIdentifier"] = "com.google.Chrome"
        chrome["title"] = "A Chrome video"
        adapter.emit(diff: false, chrome)
        try await Self.until { model.nowPlaying?.title == "A Chrome video" && page.track?.title == "A Chrome video" }
        #expect(model.nowPlaying?.title == "A Chrome video" && page.track?.title == "A Chrome video",
                "other apps on, and another app's track is not on the card and the New Tab page")
        otherApps.on = false
        try await Self.until { adapter.stops == 1 && model.nowPlaying == nil }
        #expect(adapter.stops == 1 && model.nowPlaying == nil, "turning other apps off kept the stream or the card")
    }
}

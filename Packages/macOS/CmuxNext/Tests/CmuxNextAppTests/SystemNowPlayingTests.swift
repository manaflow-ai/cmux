import AppKit
@testable import CmuxNextAgentPane
import CmuxNextCompat
@testable import CmuxNextNowPlaying
import CmuxNextSidebar
import CmuxNextTrace
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// Other apps on the Now Playing card (Spotify, Music), read from macOS Now Playing through the
/// MediaRemote adapter's JSON lines: full and diff payloads, cmux's own entries left out, the
/// controls sent back as adapter commands, the order among the card's sources, and the adapter's
/// life: started on the first need, stopped at once when a setting turns it off and a minute after
/// the last surface stopped showing it.
@MainActor @Suite struct SystemNowPlayingTests {
    final class FakeAdapter: SystemNowPlayingAdapter {
        var onUpdate: (@MainActor (SystemNowPlayingFeed.Update) -> Void)?
        var starts = 0, stops = 0
        var sent: [SystemNowPlayingCommand] = []
        /// A test sets it false to stand for a stream that gave up.
        var isStreaming = false
        func start(onUpdate: @escaping @MainActor (SystemNowPlayingFeed.Update) -> Void) {
            starts += 1
            self.onUpdate = onUpdate
            isStreaming = true
        }
        func stop() {
            stops += 1
            onUpdate = nil
            isStreaming = false
        }
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

    /// A stream that ends less than 10 s (trace clock) after its start is a quick exit: each one in a row
    /// doubles the wait before the next start, the fifth gives up, and a run of 10 s or more clears the count.
    @Test func quickExitsInARowBackOffAndThenGiveUp() {
        let uptime = UptimeNanos(1_000_000_000_000)
        var restarts = AdapterRestarts(clock: TraceClock(reader: .init(uptimeNanos: { uptime.nanos },
                                                                       continuousNow: { ContinuousClock.now })))
        let second: UInt64 = 1_000_000_000
        func run(_ nanos: UInt64) -> Duration? {
            restarts.started()
            uptime.advance(nanos)
            return restarts.exited(atNanos: uptime.nanos)
        }

        #expect(run(AdapterRestarts.quickExitNanos - 1) == .seconds(2))
        #expect(restarts.quickExits == 1)
        #expect(run(AdapterRestarts.quickExitNanos) == .seconds(1), "a 10 s run is not quick")
        #expect(restarts.quickExits == 0)

        #expect(run(2 * second) == .seconds(2))
        #expect(run(0) == .seconds(4))
        #expect(run(9 * second) == .seconds(8))
        #expect(run(1) == .seconds(16))
        #expect(run(second) == nil, "the fifth quick exit in a row gives up")
        restarts.reset()
        #expect(run(second) == .seconds(2), "a new start counts from zero")
    }

    @Test func commandsAreTheAdaptersArguments() {
        #expect(SystemNowPlayingCommand.togglePlayPause.arguments == ["send", "2"])
        #expect(SystemNowPlayingCommand.next.arguments == ["send", "4"])
        #expect(SystemNowPlayingCommand.previous.arguments == ["send", "5"])
        #expect(SystemNowPlayingCommand.seek(61.5).arguments == ["seek", "61500000"])
        #expect(SystemNowPlayingCommand.seek(-3).arguments == ["seek", "0"])
    }

    /// Counts the adapter's spawns; the launcher's fake `spawn` starts no process.
    nonisolated final class SpawnCount: Sendable {
        private let count = Mutex(0)
        func add() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    /// A source whose idle stop is a deadline on `rig`, which fires only when the test says.
    static func source(_ adapter: any SystemNowPlayingAdapter, ignoring ignored: Set<String> = [],
                       rig: MainDeadlineRig = MainDeadlineRig()) -> SystemNowPlaying {
        SystemNowPlaying(adapter: adapter, ignoring: ignored, labels: Self.labels,
                         deadlines: rig.deadlines)
    }

    /// Whether the rig's one pending wake is the idle stop, `SystemNowPlaying.idleStop` from now.
    static func idleStopIsDue(_ rig: MainDeadlineRig) -> Bool {
        guard let next = rig.deadlines.nextFire else { return false }
        return next >= SystemNowPlaying.idleStop && next <= SystemNowPlaying.idleStop + .seconds(1)
    }

    @Test func anotherAppIsOnTheCardAndItsControlsGoBack() throws {
        let adapter = FakeAdapter()
        let rig = MainDeadlineRig()
        let source = Self.source(adapter, ignoring: ["com.cmux.next"], rig: rig)
        source.run(.shown)
        source.run(.shown)
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
        source.run(.idle)
        #expect(source.nowPlaying == nil, "no surface shows Now Playing, and the track still shows")
        adapter.emit(diff: false, Self.spotify)
        #expect(source.nowPlaying == nil, "a line in the idle minute showed")
        #expect(adapter.stops == 0, "the adapter stopped at once, not a minute after the last surface")
        #expect(Self.idleStopIsDue(rig), "no idle stop a minute after the last surface")
        rig.fireAndRun()
        #expect(adapter.stops == 1, "the adapter outlived its idle stop")
        // A line the stopped stream still had in flight (FakeAdapter.stop dropped its handler).
        let late = try #require(SystemNowPlayingFeed.Update.decode(Self.line(diff: false, Self.spotify)))
        source.receive(late)
        source.run(.shown)
        #expect(adapter.starts == 2 && source.nowPlaying == nil, "stopping kept the last track, or a line after the stop showed")
    }

    /// A setting that turns Now Playing off (the card and the New Tab player off, other apps off)
    /// stops the adapter now: macOS Now Playing is not read a minute longer.
    @Test func aSettingThatTurnsNowPlayingOffStopsTheAdapterAtOnce() {
        let adapter = FakeAdapter()
        let rig = MainDeadlineRig()
        let source = Self.source(adapter, rig: rig)
        source.run(.shown)
        source.run(.off)
        #expect(adapter.stops == 1, "turning Now Playing off kept the adapter running")
        #expect(rig.deadlines.nextFire == nil, "turning Now Playing off armed an idle stop")
        source.run(.shown)
        source.run(.idle)
        #expect(Self.idleStopIsDue(rig))
        source.run(.off)
        #expect(adapter.stops == 2 && rig.deadlines.nextFire == nil, "turning Now Playing off while idle waited for the idle stop")
        source.run(.idle)
        #expect(adapter.starts == 2, "a setting on with no surface showing started the adapter")
    }

    /// A stream that gave up (it kept exiting at once) starts again when a surface shows Now
    /// Playing again within the idle minute, as turning Now Playing off and on always did.
    @Test func aSurfaceThatComesBackStartsAStreamThatGaveUp() {
        let adapter = FakeAdapter()
        let rig = MainDeadlineRig()
        let source = Self.source(adapter, rig: rig)
        source.run(.shown)
        adapter.isStreaming = false
        source.run(.idle)
        source.run(.shown)
        #expect(adapter.starts == 2, "a surface that came back kept a stream that gave up")
        source.run(.idle)
        source.run(.shown)
        #expect(adapter.starts == 2, "a surface that came back started a stream that runs again")
    }

    @Test func theNeedIsTheCardsAndTheNewTabPlayers() {
        #expect(NowPlayingNeed(card: false, cardHidden: false, newTab: false) == .off)
        #expect(NowPlayingNeed(card: false, cardHidden: true, newTab: false) == .off)
        #expect(NowPlayingNeed(card: true, cardHidden: false, newTab: false) == .shown)
        #expect(NowPlayingNeed(card: true, cardHidden: true, newTab: false) == .idle)
        #expect(NowPlayingNeed(card: true, cardHidden: true, newTab: true) == .shown)
        #expect(NowPlayingNeed(card: false, cardHidden: false, newTab: true) == .shown)
    }

    /// The adapter (a perl process) starts on the first need, never when the source
    /// is made, keeps running through a need that comes back within a minute (no new spawn), and
    /// stops one minute after the last need. The real adapter over a launcher whose spawn only counts.
    @Test func thePerlAdapterStartsOnFirstNeedAndStopsAMinuteAfterTheLast() async throws {
        let spawns = SpawnCount()
        // Qualified: CmuxNextAgentPane's ProcessLauncher shadows CmuxNextWakeups' in this file.
        let launcher = CmuxNextWakeups.ProcessLauncher(label: "com.cmuxterm.next.test.now-playing", priority: .userVisible,
                                                       spawn: { _ in spawns.add() })
        let rig = MainDeadlineRig()
        let adapter = MediaRemoteAdapterProcess(script: URL(fileURLWithPath: "/nonexistent/mediaremote-adapter.pl"),
                                                framework: URL(fileURLWithPath: "/nonexistent/MediaRemoteAdapter.framework"),
                                                deadlines: rig.deadlines,
                                                launcher: launcher)
        let source = Self.source(adapter, rig: rig)
        #expect(!adapter.isStreaming && spawns.value == 0, "the adapter launched before anything needed it")
        source.run(.shown)
        #expect(adapter.isStreaming, "the first need did not start the adapter")
        try await Self.until { spawns.value == 1 }
        #expect(spawns.value == 1)
        // The surface goes and comes back within the minute: the same stream serves it.
        source.run(.idle)
        #expect(Self.idleStopIsDue(rig))
        rig.advance(by: .seconds(30))
        source.run(.shown)
        #expect(rig.deadlines.nextFire == nil, "a need that came back kept the idle stop")
        rig.fireAndRun()
        #expect(adapter.isStreaming, "a need that came back did not keep the stream")
        // The last need ends: the stream runs until the deadline, then stops.
        source.run(.idle)
        #expect(adapter.isStreaming, "the adapter stopped before its idle deadline")
        #expect(Self.idleStopIsDue(rig), "the idle stop is not a minute after the last need")
        rig.fireAndRun()
        #expect(!adapter.isStreaming, "the adapter outlived its idle deadline")
        #expect(spawns.value == 1, "a need within the minute spawned a second adapter")
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
        let rig = MainDeadlineRig()
        let system = Self.source(adapter, rig: rig)
        let sources = NowPlayingSources(player: MusicPlayer(labels: Self.labels), tabs: FakeSource(), system: system, otherApps: { true })
        let model = SidebarModel()
        let flag = Flag(false)
        let feed = model.followNowPlaying(sources, enabled: { flag.on }, on: linklessMainWork())
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
        try await Self.until { model.nowPlaying == nil && adapter.stops == 1 }
        #expect(model.nowPlaying == nil, "turning Now Playing off kept the card")
        #expect(adapter.stops == 1, "turning Now Playing off kept the stream")
        #expect(rig.deadlines.nextFire == nil, "turning Now Playing off waited for the idle stop")
    }

    /// The card put away until relaunch, with the New Tab player off, shows Now Playing nowhere:
    /// the adapter stops a minute later and starts again on Show Media Card. A card hidden for one
    /// track keeps it running, since other media brings that card back.
    @Test func aCardHiddenUntilRelaunchStopsTheAdapterAMinuteLater() async throws {
        let adapter = FakeAdapter()
        let rig = MainDeadlineRig()
        let system = Self.source(adapter, rig: rig)
        let sources = NowPlayingSources(player: MusicPlayer(labels: Self.labels), tabs: FakeSource(), system: system, otherApps: { true })
        let model = SidebarModel()
        let dismissal = NowPlayingCardDismissal()
        let feed = model.followNowPlaying(sources, dismissal: dismissal, enabled: { true }, on: linklessMainWork())
        defer { feed.cancel() }
        try await Self.until { adapter.starts == 1 }
        adapter.emit(diff: false, Self.spotify)
        try await Self.until { model.nowPlaying?.title == "Weightless" }
        #expect(dismissal.hideShown())
        try await Self.until { model.nowPlaying == nil }
        #expect(model.nowPlaying == nil, "the card hidden for its track still shows")
        #expect(rig.deadlines.nextFire == nil && adapter.stops == 0, "a card hidden for one track stopped reading what plays")
        dismissal.hideUntilRelaunch()
        try await Self.until { Self.idleStopIsDue(rig) }
        #expect(Self.idleStopIsDue(rig), "a card hidden until relaunch armed no idle stop")
        #expect(adapter.stops == 0, "a card hidden until relaunch stopped the adapter at once")
        rig.fireAndRun()
        #expect(adapter.stops == 1, "a card hidden until relaunch kept the adapter past its idle stop")
        dismissal.reset()
        try await Self.until { adapter.starts == 2 }
        #expect(adapter.starts == 2, "Show Media Card did not start the adapter again")
    }

    @Test func cmuxsOwnEntriesAreLeftOut() {
        let adapter = FakeAdapter()
        let source = Self.source(adapter, ignoring: ["com.cmux.next"])
        source.run(.shown)
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
        let rig = MainDeadlineRig()
        let source = Self.source(adapter, rig: rig)
        source.run(.shown)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 600, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        var payload = Self.spotify
        payload["artworkData"] = jpeg.base64EncodedString()
        payload["artworkMimeType"] = "image/jpeg"
        adapter.emit(diff: false, payload)
        // Decoded and drawn off the main actor: the track shows at once, its artwork once ready, as one
        // visible task on the app's scheduler (the rig's runs at its frames).
        #expect(source.nowPlaying?.title == "Weightless")
        #expect(source.nowPlaying?.artwork == nil, "the artwork was drawn on the main actor, in the update's turn")
        try await Self.until {
            rig.frame()
            return source.nowPlaying?.artwork != nil
        }
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
        let rig = MainDeadlineRig()
        let system = Self.source(adapter, rig: rig)
        let otherApps = Flag(false)
        let sources = NowPlayingSources(player: MusicPlayer(labels: Self.labels), tabs: FakeSource(), system: system,
                                        otherApps: { otherApps.on })
        let model = SidebarModel()
        let page = AgentPaneNowPlaying()
        let feed = model.followNowPlaying(sources, enabled: { true }, onNewTab: { true }, player: page, on: linklessMainWork())
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
        try await Self.until { model.nowPlaying == nil && page.track == nil && adapter.stops == 1 }
        #expect(model.nowPlaying == nil && page.track == nil, "turning other apps off kept the card or the New Tab page")
        #expect(adapter.stops == 1, "turning other apps off kept reading macOS Now Playing")
        #expect(rig.deadlines.nextFire == nil, "turning other apps off waited for the idle stop")
    }
}

/// The trace clock's uptime that a test moves.
private nonisolated final class UptimeNanos: Sendable {
    private let value: Mutex<UInt64>

    init(_ nanos: UInt64) {
        value = Mutex(nanos)
    }

    var nanos: UInt64 { value.withLock { $0 } }

    func advance(_ nanos: UInt64) {
        value.withLock { $0 += nanos }
    }
}

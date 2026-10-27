import AppKit
import CmuxNextCompat
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CmuxNextBrowser
public import CmuxNextWakeups
public import CmuxNextSidebar
public import Foundation
public import Observation

/// The Now Playing card's source for other apps (Spotify, Music, a browser):
/// what macOS Now Playing reports, through ``SystemNowPlayingAdapter``, while
/// `run(_:)` says a surface shows it (the card or the New Tab player).
/// cmux's own entries (its player and browser tabs, which have their own
/// sources) are left out. The artwork is drawn into a small PNG once per
/// image; the controls go back to the app that plays.
///
/// The adapter (a `perl` process) starts on the first need, never at launch.
/// A setting that turns Now Playing off stops it at once. A surface that only
/// stops showing it (``NowPlayingNeed/idle``) stops it ``idleStop`` later, so a
/// surface that comes back within that time shows what plays at once and
/// spawns nothing. This is Chromium's idle timeout for a service process it
/// starts on demand (`mojo::Remote::reset_on_idle_timeout`, used by
/// services/data_decoder/public/cpp/data_decoder.cc).
@Observable
public final class SystemNowPlaying: NowPlayingSource {
    private var feed = SystemNowPlayingFeed()
    /// The shown report's artwork as the adapter sent it, and as a small PNG.
    private var artwork: (base64: String, data: Data?)?
    /// What the surfaces need now; observed, so a surface that shows Now Playing again shows the
    /// report the still-running stream kept.
    private(set) var need: NowPlayingNeed = .off
    @ObservationIgnored private let adapter: (any SystemNowPlayingAdapter)?
    @ObservationIgnored private let ignored: Set<String>
    @ObservationIgnored private let labels: SidebarNowPlaying.Labels
    /// Whether this source started the adapter and did not stop it since: from the first shown need
    /// until a setting turns Now Playing off, or ``idleStop`` after the last surface stopped showing it.
    @ObservationIgnored private(set) var streaming = false
    /// The one-shot deadline that stops the adapter once no surface has shown Now Playing for ``idleStop``.
    @ObservationIgnored private let idle: MainDeadline
    /// The app's main-thread scheduler: the artwork drawn off main lands as one of its visible tasks.
    @ObservationIgnored private let mainWork: MainWorkScheduler
    nonisolated static let idleStop: Duration = .seconds(60)
    nonisolated static let artworkSide = 320
    /// Decodes the shown artwork off the main actor.
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    /// The app's Launch Services answers: the playing app's name is asked on the system lane and kept there.
    /// Nil names no app.
    @ObservationIgnored public var queries: WorkspaceQueries?
    /// Bumped when an app's name lands, so ``nowPlaying`` is read again with it.
    private var appNameArrivals = 0

    /// A source over `adapter` that leaves out reports from `ignored` (cmux's bundle
    /// identifiers), with the browser media controls' titles.
    public convenience init(adapter: (any SystemNowPlayingAdapter)?, ignoring ignored: Set<String>, deadlines: MainDeadlineScheduler) {
        self.init(adapter: adapter, ignoring: ignored,
                  labels: SidebarNowPlaying.Labels(play: BrowserMediaStrings.play, pause: BrowserMediaStrings.pause,
                                                   previous: BrowserMediaStrings.previous, next: BrowserMediaStrings.next),
                  deadlines: deadlines)
    }

    /// - Parameter deadlines: the app's one deadline placer: the adapter stops ``idleStop`` after the last
    ///   surface stopped showing Now Playing (a `background` deadline: nobody sees that stop), and the drawn
    ///   artwork lands as a visible task on its scheduler.
    public init(adapter: (any SystemNowPlayingAdapter)?, ignoring ignored: Set<String>, labels: SidebarNowPlaying.Labels,
                deadlines: MainDeadlineScheduler) {
        self.adapter = adapter
        self.ignored = ignored
        self.labels = labels
        idle = MainDeadline(owner: "NowPlaying.adapterIdleStop", workClass: .background, scheduler: deadlines)
        mainWork = deadlines.work
    }

    /// Reads Now Playing for `need` (`followNowPlaying`). Shown starts the adapter, and starts it
    /// again when it gave up or waits to restart. Idle hides what plays at once and stops the
    /// adapter ``idleStop`` later, unless a surface shows Now Playing again first. Off stops it now.
    public func run(_ need: NowPlayingNeed) {
        guard need != self.need, let adapter else { return }
        self.need = need
        switch need {
        case .shown:
            idle.cancel()
            guard !streaming || !adapter.isStreaming else { return }
            streaming = true
            adapter.start { [weak self] update in self?.receive(update) }
        case .idle:
            guard streaming else { return }
            idle.schedule(after: Self.idleStop) { [weak self] in self?.stopUnlessShown() }
        case .off:
            idle.cancel()
            stopUnlessShown()
        }
    }

    /// Stops the adapter and forgets what played, unless a surface shows Now Playing again.
    private func stopUnlessShown() {
        guard need != .shown, streaming, let adapter else { return }
        streaming = false
        adapter.stop()
        artworkTask?.cancel()
        feed = SystemNowPlayingFeed()
        artwork = nil
    }

    /// cmux's source for other apps: the bundled adapter, leaving out this app's own entries, stopped
    /// ``idleStop`` after the last surface by a deadline on `deadlines` (the app's one placer).
    public static func bundled(deadlines: MainDeadlineScheduler, queries: WorkspaceQueries) -> SystemNowPlaying {
        let source = SystemNowPlaying(adapter: MediaRemoteAdapterProcess.bundled(deadlines: deadlines), ignoring: Set([Bundle.main.bundleIdentifier].compactMap { $0 }),
                                      deadlines: deadlines)
        source.queries = queries
        return source
    }

    /// What another app plays, nil while nothing does, cmux itself plays or no surface shows it.
    public var report: SystemNowPlayingReport? {
        guard need == .shown, let report = feed.report, !report.isFrom(ignored) else { return nil }
        return report
    }

    public var nowPlaying: SidebarNowPlaying? {
        guard let report else { return nil }
        let image = report.artwork.flatMap { base64 in artwork?.base64 == base64 ? artwork?.data : nil }
        return SidebarNowPlaying(
            title: report.title, artist: report.artist, artwork: image, isPlaying: report.isPlaying,
            position: report.elapsed, duration: report.duration, rate: report.rate > 0 ? report.rate : 1,
            positionDate: report.timestamp ?? Date(), canPrevious: true, canNext: true, labels: labels,
            app: app(report.parentBundleIdentifier ?? report.bundleIdentifier))
    }

    /// The app that plays as the New Tab player's Open in names it: a browser's media helper
    /// names its browser. Its name is kept per app; until it lands from the system lane, no app is named.
    func app(_ bundleIdentifier: String) -> SidebarNowPlaying.App? {
        _ = appNameArrivals
        guard let queries else { return nil }
        let query = Self.appName(of: bundleIdentifier)
        guard let kept = queries.cached(query) else {
            // Not kept, so the answer comes on a later turn, never inside this read.
            queries.value(query, priority: .userVisible) { [weak self] _ in self?.appNameArrivals += 1 }
            return nil
        }
        guard let name = kept, !name.isEmpty else { return nil }
        return SidebarNowPlaying.App(bundleIdentifier: bundleIdentifier, name: name)
    }

    /// The name Finder shows for the app with `bundleIdentifier`, nil when it is not installed: Launch Services
    /// and the disk, on the system lane. An app installed since shows once the kept answer is refreshed.
    nonisolated static func appName(of bundleIdentifier: String) -> WorkspaceQuery<String?> {
        WorkspaceQuery(id: "nowPlaying.appName." + bundleIdentifier, refreshes: true) { system in
            system.application(withBundleIdentifier: bundleIdentifier).map { Self.appName(FileManager.default.displayName(atPath: $0.path)) }
        }
    }

    /// Finder's name without the `.app` it shows when extensions are on.
    nonisolated static func appName(_ displayName: String) -> String {
        displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
    }

    public func perform(_ command: SidebarNowPlayingCommand) {
        guard report != nil, let adapter else { return }
        switch command {
        case .playPause: adapter.send(.togglePlayPause)
        case .previous: adapter.send(.previous)
        case .next: adapter.send(.next)
        case .seek(let seconds): adapter.send(.seek(seconds))
        // Another app's video floats in that app.
        case .pictureInPicture: break
        }
    }

    /// Takes one update of the adapter's stream (decoded off the main actor). New artwork is
    /// decoded and drawn small off the main actor too; the card shows it once ready.
    func receive(_ update: SystemNowPlayingFeed.Update) {
        guard streaming else { return }
        var next = feed
        next.apply(update)
        guard next != feed else { return }
        feed = next
        let base64 = next.report?.artwork
        guard base64 != artwork?.base64 else { return }
        artworkTask?.cancel()
        guard let base64 else {
            artwork = nil
            return
        }
        artwork = (base64, nil)
        // R-hop: drawn off main; the card's artwork lands as one visible task.
        let mainWork = mainWork
        artworkTask = Task.detached(priority: .utility) { [weak self] in
            let png = Data(base64Encoded: base64).flatMap { Self.png($0, side: Self.artworkSide) }
            mainWork.postFromAnyThread(.visible, owner: "NowPlaying.systemArtwork") { [weak self] in
                guard let self, self.artwork?.base64 == base64 else { return }
                self.artwork = (base64, png)
            }
        }
    }

    /// The image drawn into a `side`-pixel square, as PNG. ImageIO and Core Graphics, so it runs
    /// on any thread.
    nonisolated static func png(_ data: Data, side: Int) -> Data? {
        guard let image = blockingImageDecode(data),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let scaled = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

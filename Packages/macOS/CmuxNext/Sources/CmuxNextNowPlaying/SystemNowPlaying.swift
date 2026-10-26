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
/// `run(_:)` says a surface needs it (the card or the New Tab player shows it).
/// cmux's own entries (its player and browser tabs, which have their own
/// sources) are left out. The artwork is drawn into a small PNG once per
/// image; the controls go back to the app that plays.
///
/// The adapter (a `perl` process) starts on the first need, never at launch,
/// and stops ``idleStop`` after the last need ends, so a surface that comes
/// back within that time shows what plays at once and spawns nothing. This is
/// Chromium's idle timeout for a service process it starts on demand
/// (`mojo::Remote::reset_on_idle_timeout`, used by
/// services/data_decoder/public/cpp/data_decoder.cc): the process ends only
/// after it went unused for a while, never on each release.
@Observable
public final class SystemNowPlaying: NowPlayingSource {
    private var feed = SystemNowPlayingFeed()
    /// The shown report's artwork as the adapter sent it, and as a small PNG.
    private var artwork: (base64: String, data: Data?)?
    /// Whether a surface needs Now Playing now; observed, so a need that comes back shows the report
    /// the still-running stream kept.
    private(set) var needed = false
    @ObservationIgnored private let adapter: (any SystemNowPlayingAdapter)?
    @ObservationIgnored private let ignored: Set<String>
    @ObservationIgnored private let labels: SidebarNowPlaying.Labels
    /// Whether the adapter streams: from the first need until ``idleStop`` after the last.
    @ObservationIgnored private(set) var streaming = false
    /// The one-shot deadline that stops the adapter once no surface has needed it for ``idleStop``; nil
    /// stops it as soon as the last need ends.
    @ObservationIgnored private let idle: MainDeadline?
    nonisolated static let idleStop: Duration = .seconds(60)
    nonisolated static let artworkSide = 320
    /// Decodes the shown artwork off the main actor.
    @ObservationIgnored private var artworkTask: Task<Void, Never>?

    /// A source over `adapter` that leaves out reports from `ignored` (cmux's bundle
    /// identifiers), with the browser media controls' titles.
    public convenience init(adapter: (any SystemNowPlayingAdapter)?, ignoring ignored: Set<String>, idle: MainDeadline?) {
        self.init(adapter: adapter, ignoring: ignored,
                  labels: SidebarNowPlaying.Labels(play: BrowserMediaStrings.play, pause: BrowserMediaStrings.pause,
                                                   previous: BrowserMediaStrings.previous, next: BrowserMediaStrings.next),
                  idle: idle)
    }

    /// - Parameter idle: the deadline that stops the adapter ``idleStop`` after the last need (nobody
    ///   sees that stop: its class is `background`); nil stops it when the last need ends.
    public init(adapter: (any SystemNowPlayingAdapter)?, ignoring ignored: Set<String>, labels: SidebarNowPlaying.Labels,
                idle: MainDeadline?) {
        self.adapter = adapter
        self.ignored = ignored
        self.labels = labels
        self.idle = idle
    }

    /// Reads Now Playing while `on` (a surface shows it, `followNowPlaying`): the first need starts the
    /// adapter. Off hides what plays at once and stops the adapter ``idleStop`` later, unless a need
    /// comes back first.
    public func run(_ on: Bool) {
        guard on != needed, let adapter else { return }
        needed = on
        guard on else {
            guard let idle else { return stopIdle() }
            idle.schedule(after: Self.idleStop) { [weak self] in self?.stopIdle() }
            return
        }
        idle?.cancel()
        guard !streaming else { return }
        streaming = true
        adapter.start { [weak self] update in self?.receive(update) }
    }

    /// The idle deadline: stops the adapter and forgets what played, unless a surface needs it again.
    private func stopIdle() {
        guard !needed, streaming, let adapter else { return }
        streaming = false
        adapter.stop()
        artworkTask?.cancel()
        feed = SystemNowPlayingFeed()
        artwork = nil
    }

    /// cmux's source for other apps: the bundled adapter, leaving out this app's own entries, stopped
    /// ``idleStop`` after the last need by a deadline on `deadlines` (the app's one placer).
    public static func bundled(deadlines: MainDeadlineScheduler?) -> SystemNowPlaying {
        SystemNowPlaying(adapter: MediaRemoteAdapterProcess.bundled(), ignoring: Set([Bundle.main.bundleIdentifier].compactMap { $0 }),
                         idle: deadlines.map { MainDeadline(owner: "NowPlaying.adapterIdleStop", workClass: .background, scheduler: $0) })
    }

    /// What another app plays, nil while nothing does, cmux itself plays or no surface needs it.
    public var report: SystemNowPlayingReport? {
        guard needed, let report = feed.report, !report.isFrom(ignored) else { return nil }
        return report
    }

    public var nowPlaying: SidebarNowPlaying? {
        guard let report else { return nil }
        let image = report.artwork.flatMap { base64 in artwork?.base64 == base64 ? artwork?.data : nil }
        return SidebarNowPlaying(
            title: report.title, artist: report.artist, artwork: image, isPlaying: report.isPlaying,
            position: report.elapsed, duration: report.duration, rate: report.rate > 0 ? report.rate : 1,
            positionDate: report.timestamp ?? Date(), canPrevious: true, canNext: true, labels: labels,
            app: Self.app(report.parentBundleIdentifier ?? report.bundleIdentifier))
    }

    /// The names of the apps that played, by bundle identifier. An app not found is looked up again
    /// next time (it may be installed since).
    private static var appNames: [String: String] = [:]

    /// The app that plays as the New Tab player's Open in names it: a browser's media helper
    /// names its browser. Looked up once per app (one Launch Services read).
    static func app(_ bundleIdentifier: String) -> SidebarNowPlaying.App? {
        if appNames[bundleIdentifier] == nil,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            appNames[bundleIdentifier] = appName(FileManager.default.displayName(atPath: url.path))
        }
        guard let name = appNames[bundleIdentifier], !name.isEmpty else { return nil }
        return SidebarNowPlaying.App(bundleIdentifier: bundleIdentifier, name: name)
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
        artworkTask = Task.detached(priority: .utility) { [weak self] in
            let png = Data(base64Encoded: base64).flatMap { Self.png($0, side: Self.artworkSide) }
            await MainActor.run { [weak self] in
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

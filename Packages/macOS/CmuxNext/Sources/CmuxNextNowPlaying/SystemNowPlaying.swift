import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CmuxNextBrowser
import CmuxNextWakeups
public import CmuxNextSidebar
public import Foundation
public import Observation

/// The Now Playing card's source for other apps (Spotify, Music, a browser):
/// what macOS Now Playing reports, through ``SystemNowPlayingAdapter``, while
/// `run(_:)` keeps it running (the card shows). cmux's own entries (its
/// player and browser tabs, which have their own sources) are left out. The
/// artwork is drawn into a small PNG once per image; the controls go back to
/// the app that plays. Play or Pause shows at once: the app reports the change
/// a moment later (Spotify: up to a second), so until it does, or until
/// ``pendingWait`` passes with no report, the card shows the asked state.
@Observable
public final class SystemNowPlaying: NowPlayingSource {
    private var feed = SystemNowPlayingFeed()
    /// The shown report's artwork as the adapter sent it, and as a small PNG.
    private var artwork: (base64: String, data: Data?)?
    @ObservationIgnored private let adapter: (any SystemNowPlayingAdapter)?
    @ObservationIgnored private let ignored: Set<String>
    @ObservationIgnored private let labels: SidebarNowPlaying.Labels
    @ObservationIgnored private(set) var running = false
    nonisolated static let artworkSide = 320
    /// Decodes the shown artwork off the main actor.
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    /// A Play or Pause asked for and not reported yet: what the card shows meanwhile.
    private var pending: Pending?
    @ObservationIgnored private let pendingTimeout = DemandTimer(owner: "now-playing.system-pending")
    /// Bumped by each press, so a wait that fires as a new press lands leaves the new one.
    @ObservationIgnored private var pendingCount = 0
    /// How long an asked Play or Pause shows with no report before the card goes back to what the app says.
    @ObservationIgnored let pendingWait: Duration

    /// The asked state for one track: playing or not, from this position at `date`.
    private struct Pending: Equatable {
        var playing: Bool
        var position: TimeInterval?
        var date: Date
        var mediaKey: String
    }

    /// A source over `adapter` that leaves out reports from `ignored` (cmux's bundle
    /// identifiers), with the browser media controls' titles.
    public convenience init(adapter: (any SystemNowPlayingAdapter)?, ignoring ignored: Set<String>) {
        self.init(adapter: adapter, ignoring: ignored,
                  labels: SidebarNowPlaying.Labels(play: BrowserMediaStrings.play, pause: BrowserMediaStrings.pause,
                                                   previous: BrowserMediaStrings.previous, next: BrowserMediaStrings.next))
    }

    public init(adapter: (any SystemNowPlayingAdapter)?, ignoring ignored: Set<String>, labels: SidebarNowPlaying.Labels,
                pendingWait: Duration = .seconds(3)) {
        self.adapter = adapter
        self.ignored = ignored
        self.labels = labels
        self.pendingWait = pendingWait
    }

    /// Streams Now Playing while `on` (the card follows it, `followNowPlaying`); off stops the
    /// adapter and forgets what played.
    public func run(_ on: Bool) {
        guard on != running, let adapter else { return }
        running = on
        if on {
            adapter.start { [weak self] update in self?.receive(update) }
        } else {
            adapter.stop()
            artworkTask?.cancel()
            settlePending()
            feed = SystemNowPlayingFeed()
            artwork = nil
        }
    }

    /// cmux's source for other apps: the bundled adapter, leaving out this app's own entries.
    public static func bundled() -> SystemNowPlaying {
        SystemNowPlaying(adapter: MediaRemoteAdapterProcess.bundled(), ignoring: Set([Bundle.main.bundleIdentifier].compactMap { $0 }))
    }

    /// What another app plays, nil while nothing does or cmux itself plays.
    public var report: SystemNowPlayingReport? {
        guard let report = feed.report, !report.isFrom(ignored) else { return nil }
        return report
    }

    public var nowPlaying: SidebarNowPlaying? {
        guard let report else { return nil }
        let image = report.artwork.flatMap { base64 in artwork?.base64 == base64 ? artwork?.data : nil }
        var shown = SidebarNowPlaying(
            title: report.title, artist: report.artist, artwork: image, isPlaying: report.isPlaying,
            position: report.elapsed, duration: report.duration, rate: report.rate > 0 ? report.rate : 1,
            positionDate: report.timestamp ?? Date(), canPrevious: true, canNext: true, labels: labels,
            app: Self.app(report.parentBundleIdentifier ?? report.bundleIdentifier))
        if let pending, pending.mediaKey == shown.mediaKey {
            shown.isPlaying = pending.playing
            shown.position = pending.position
            shown.positionDate = pending.date
        }
        return shown
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
        case .playPause:
            showPending()
            adapter.send(.togglePlayPause)
        case .previous: adapter.send(.previous)
        case .next: adapter.send(.next)
        case .seek(let seconds):
            // A seek while a press waits shows where it went, still as pressed.
            if pending != nil { pending?.position = seconds; pending?.date = Date() }
            adapter.send(.seek(seconds))
        // Another app's video floats in that app.
        case .pictureInPicture: break
        }
    }

    /// Shows the other state of the shown track at once, from where it is now, until the app
    /// reports it or ``pendingWait`` passes. A second press before the report flips it back.
    private func showPending() {
        guard let shown = nowPlaying else { return }
        let now = Date()
        pending = Pending(playing: !shown.isPlaying, position: shown.position(at: now), date: now, mediaKey: shown.mediaKey)
        pendingCount &+= 1
        let press = pendingCount
        pendingTimeout.schedule(after: pendingWait) { @MainActor [weak self] in
            guard let self, self.pendingCount == press else { return }
            self.pending = nil
        }
    }

    private func settlePending() {
        pendingTimeout.cancel()
        if pending != nil { pending = nil }
    }

    /// Whether the report settles the asked state: the app's report read after the press (playing
    /// or not, so a seek or Previous it did shows), or with no read time one that plays as asked,
    /// or another track. A report read before the press holds the old position and changes nothing.
    private var pendingSettled: Bool {
        guard let pending else { return false }
        guard let report, nowPlaying?.mediaKey == pending.mediaKey else { return true }
        guard let read = report.timestamp else { return report.isPlaying == pending.playing }
        return read >= pending.date
    }

    /// Takes one update of the adapter's stream (decoded off the main actor). New artwork is
    /// decoded and drawn small off the main actor too; the card shows it once ready.
    func receive(_ update: SystemNowPlayingFeed.Update) {
        guard running else { return }
        var next = feed
        next.apply(update)
        guard next != feed else { return }
        feed = next
        if pendingSettled { settlePending() }
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
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
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

import AppKit
import CmuxNextBrowser
public import CmuxNextSidebar
public import Foundation
public import Observation

/// The Now Playing card's source for other apps (Spotify, Music, a browser):
/// what macOS Now Playing reports, through ``SystemNowPlayingAdapter``, while
/// `run(_:)` keeps it running (the card shows). cmux's own entries (its
/// player and browser tabs, which have their own sources) are left out. The
/// artwork is drawn into a small PNG once per image; the controls go back to
/// the app that plays.
@Observable
public final class SystemNowPlaying: NowPlayingSource {
    private var feed = SystemNowPlayingFeed()
    /// The shown report's artwork as the adapter sent it, and as a small PNG.
    private var artwork: (base64: String, data: Data?)?
    @ObservationIgnored private let adapter: (any SystemNowPlayingAdapter)?
    @ObservationIgnored private let ignored: Set<String>
    @ObservationIgnored private let labels: SidebarNowPlaying.Labels
    @ObservationIgnored private(set) var running = false
    private static let artworkSide = 320

    /// A source over `adapter` that leaves out reports from `ignored` (cmux's bundle
    /// identifiers), with the browser media controls' titles.
    public convenience init(adapter: (any SystemNowPlayingAdapter)?, ignoring ignored: Set<String>) {
        self.init(adapter: adapter, ignoring: ignored,
                  labels: SidebarNowPlaying.Labels(play: BrowserMediaStrings.play, pause: BrowserMediaStrings.pause,
                                                   previous: BrowserMediaStrings.previous, next: BrowserMediaStrings.next))
    }

    public init(adapter: (any SystemNowPlayingAdapter)?, ignoring ignored: Set<String>, labels: SidebarNowPlaying.Labels) {
        self.adapter = adapter
        self.ignored = ignored
        self.labels = labels
    }

    /// Streams Now Playing while `on` (the card follows it, `followNowPlaying`); off stops the
    /// adapter and forgets what played.
    public func run(_ on: Bool) {
        guard on != running, let adapter else { return }
        running = on
        if on {
            adapter.start { [weak self] line in self?.receive(line) }
        } else {
            adapter.stop()
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
        return SidebarNowPlaying(
            title: report.title, artist: report.artist, artwork: image, isPlaying: report.isPlaying,
            position: report.elapsed, duration: report.duration, rate: report.rate > 0 ? report.rate : 1,
            positionDate: report.timestamp ?? Date(), canPrevious: true, canNext: true, labels: labels)
    }

    public func perform(_ command: SidebarNowPlayingCommand) {
        guard report != nil, let adapter else { return }
        switch command {
        case .playPause: adapter.send(.togglePlayPause)
        case .previous: adapter.send(.previous)
        case .next: adapter.send(.next)
        case .seek(let seconds): adapter.send(.seek(seconds))
        }
    }

    /// Takes one line of the adapter's stream.
    func receive(_ line: Data) {
        guard running else { return }
        var next = feed
        guard next.apply(line), next != feed else { return }
        feed = next
        let base64 = next.report?.artwork
        guard base64 != artwork?.base64 else { return }
        artwork = base64.map { ($0, Data(base64Encoded: $0).flatMap(Self.png)) }
    }

    /// The image drawn into a small square bitmap, as PNG.
    static func png(_ data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let side = artworkSide
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}

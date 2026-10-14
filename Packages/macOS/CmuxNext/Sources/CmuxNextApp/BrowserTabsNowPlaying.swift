import AppKit
import CmuxNextBrowser
import CmuxNextSidebar
import Observation

/// The sidebar Now Playing card's source (cx-ouoxo): the browser tab that
/// plays, in either engine, picked the way macOS Now Playing picks it
/// (`BrowserNowPlaying.pick`), with its artwork loaded through the tab
/// (its cookies, its proxy). Controls run the media hub's commands on it.
@Observable
final class BrowserTabsNowPlaying: NowPlayingSource {
    @ObservationIgnored private weak var services: AppServices?
    /// Bumped when `follow` changes the services, so readers look again.
    private var generation = 0
    /// The tab the card showed last; it keeps the card while it plays.
    @ObservationIgnored private var shown: BrowserNowPlaying.Session?
    /// The shown tab's artwork, small PNG data once loaded (nil while loading or without art).
    private var artwork: (url: URL, data: Data?)?
    private static let artworkSide: CGFloat = 96

    func follow(_ services: AppServices?) {
        self.services = services
        generation &+= 1
    }

    var nowPlaying: SidebarNowPlaying? {
        _ = generation
        guard let services else { return nil }
        let sessions = services.cache.pageRequests.media.sessions(in: services.cache)
            .map { BrowserNowPlaying.Session(tab: $0.entry.tab.id, media: $0.media) }
        shown = BrowserNowPlaying.pick(after: shown, from: sessions)
        guard let shown else { return nil }
        let media = shown.media
        return SidebarNowPlaying(
            title: media.title, artist: media.artist, artwork: artworkData(media.artworkURL, tab: shown.tab), isPlaying: media.isPlaying,
            position: media.position, duration: media.duration, rate: media.rate, positionDate: media.positionDate,
            canPrevious: media.actions.contains(.previoustrack), canNext: media.actions.contains(.nexttrack),
            labels: SidebarNowPlaying.Labels(play: BrowserMediaStrings.play, pause: BrowserMediaStrings.pause,
                                             previous: BrowserMediaStrings.previous, next: BrowserMediaStrings.next))
    }

    func perform(_ command: SidebarNowPlayingCommand) {
        guard let shown, let tab = browserTab(shown.tab) else { return }
        let media: BrowserMediaCommand = switch command {
        case .playPause: .playPause
        case .previous: .previousTrack
        case .next: .nextTrack
        case .seek(let seconds): .seek(seconds)
        }
        Task { await tab.media(media) }
    }

    private func browserTab(_ id: BrowserTabID) -> (any BrowserTab)? {
        services?.cache.browsers.values.first { $0.tab.id == id }?.tab
    }

    /// The artwork for `url` once loaded; asks the tab for it the first time.
    private func artworkData(_ url: URL?, tab id: BrowserTabID) -> Data? {
        guard let url else { return nil }
        if let artwork, artwork.url == url { return artwork.data }
        // Loaded after this read returns, so the read never writes what it observes.
        Task { [weak self] in self?.loadArtwork(url, tab: id) }
        return nil
    }

    private func loadArtwork(_ url: URL, tab id: BrowserTabID) {
        guard artwork?.url != url, let tab = browserTab(id) else { return }
        artwork = (url, nil)
        Task { [weak self] in
            let image = await tab.fetchFavicon(url)
            guard let self, self.artwork?.url == url else { return }
            self.artwork = (url, image.flatMap(Self.png))
        }
    }

    /// The image drawn into a small square bitmap, as PNG.
    private static func png(_ image: NSImage) -> Data? {
        let side = Int(artworkSide)
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

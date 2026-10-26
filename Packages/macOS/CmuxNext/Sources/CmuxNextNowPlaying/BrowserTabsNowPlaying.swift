import AppKit
public import CmuxNextBrowser
public import CmuxNextSidebar
public import Observation
import CmuxNextWakeups

/// The sidebar Now Playing card's source (cx-ouoxo): the browser tab that
/// plays, in either engine, picked the way macOS Now Playing picks it
/// (`NowPlayingSession.pick`), with its artwork loaded through the tab
/// (its cookies, its proxy). Controls run the media hub's commands on it.
/// The App hands it the tabs (`follow`); reading them while observing tracks them.
@Observable
public final class BrowserTabsNowPlaying: NowPlayingSource {
    @ObservationIgnored private var sessions: () -> [NowPlayingSession] = { [] }
    @ObservationIgnored private var browserTab: (BrowserTabID) -> (any BrowserTab)? = { _ in nil }
    /// `media.pictureInPicture.enabled`: off, the card offers no Picture in Picture and its button does nothing.
    /// The App sets it; reading it while observing tracks the setting.
    @ObservationIgnored public var allowsPictureInPicture: () -> Bool = { true }
    /// Bumped when `follow` changes the tabs, so readers look again.
    private var generation = 0
    /// The tab the card showed last; it keeps the card while it plays.
    @ObservationIgnored private var shown: NowPlayingSession?
    /// The shown tab's artwork, small PNG data once loaded (nil while loading or without art).
    private var artwork: (url: URL, data: Data?)?
    private static let artworkSide: CGFloat = 96
    /// How long after a failed artwork fetch the tab is asked again, doubling with each failure
    /// up to ``artworkRetryLimit`` (tests shorten it).
    @ObservationIgnored var artworkRetry: Duration = .seconds(10)
    private static let artworkRetryLimit: Duration = .seconds(300)
    /// The artwork URL whose fetches failed, and how many times in a row.
    @ObservationIgnored private var artworkFailures: (url: URL, count: Int)?
    @ObservationIgnored private let artworkWait = DemandTimer(owner: "now-playing.artwork-retry")

    public init() {}

    /// Follows these tabs: the media sessions in either engine, and a tab by its id.
    public func follow(sessions: @escaping () -> [NowPlayingSession], tab: @escaping (BrowserTabID) -> (any BrowserTab)?) {
        self.sessions = sessions
        browserTab = tab
        generation &+= 1
    }

    public var nowPlaying: SidebarNowPlaying? {
        _ = generation
        shown = NowPlayingSession.pick(after: shown, from: sessions())
        guard let shown else { return nil }
        let media = shown.media
        return SidebarNowPlaying(
            title: media.title, artist: media.artist, artwork: artworkData(media.artworkURL, tab: shown.tab), isPlaying: media.isPlaying,
            position: media.position, duration: media.duration, rate: media.rate, positionDate: media.positionDate,
            canPrevious: media.actions.contains(.previoustrack), canNext: media.actions.contains(.nexttrack),
            site: Self.site(browserTab(shown.tab)?.state.url), canPictureInPicture: media.isVideo && allowsPictureInPicture(),
            isPictureInPicture: media.isPictureInPicture,
            labels: SidebarNowPlaying.Labels(play: BrowserMediaStrings.play, pause: BrowserMediaStrings.pause,
                                             previous: BrowserMediaStrings.previous, next: BrowserMediaStrings.next,
                                             pictureInPicture: BrowserMediaStrings.pictureInPicture,
                                             exitPictureInPicture: BrowserMediaStrings.exitPictureInPicture))
    }

    /// The page's site as macOS Now Playing names it: its host without `www.`.
    static func site(_ url: URL?) -> String {
        guard let host = url?.host(percentEncoded: false), !host.isEmpty else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The tab the card shows, picked as ``nowPlaying`` picks it; nil while no tab plays.
    public var shownTab: BrowserTabID? { nowPlaying == nil ? nil : shown?.tab }

    public func perform(_ command: SidebarNowPlayingCommand) {
        guard let shown, let tab = browserTab(shown.tab) else { return }
        if command == .pictureInPicture, !allowsPictureInPicture() { return }
        let media: BrowserMediaCommand = switch command {
        case .playPause: .playPause
        case .previous: .previousTrack
        case .next: .nextTrack
        case .seek(let seconds): .seek(seconds)
        case .pictureInPicture: .pictureInPicture
        }
        Task { [weak self] in
            // A press still in flight when the setting turns off does nothing.
            if media == .pictureInPicture, self?.allowsPictureInPicture() == false { return }
            await tab.media(media)
        }
    }

    /// The artwork for `url` once loaded; asks the tab for it the first time, and again a while
    /// after a fetch that failed (the tab was still loading, the network dropped).
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
            guard let data = image.flatMap(Self.png) else {
                self.artworkFailed(url)
                return
            }
            self.artworkFailures = nil
            self.artwork = (url, data)
        }
    }

    /// Forgets the failed fetch a while later: readers look again and the next read asks the tab anew.
    private func artworkFailed(_ url: URL) {
        let count = artworkFailures?.url == url ? (artworkFailures?.count ?? 0) + 1 : 1
        artworkFailures = (url, count)
        let delay = min(artworkRetry * (1 << min(count - 1, 16)), Self.artworkRetryLimit)
        artworkWait.schedule(after: delay) { @MainActor [weak self] in
            guard let self, self.artwork?.url == url, self.artwork?.data == nil else { return }
            self.artwork = nil
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

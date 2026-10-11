import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import MediaPlayer

/// The playing Chromium tab in macOS Now Playing (Control Center, the lock
/// screen) and on the media keys (cx-6qwm.3), from the media hub's
/// sessions: an audible playing tab, else the tab shown so far while it
/// stays (paused or muted), else a muted playing one. Play, pause and
/// play/pause run the hub's play/pause on that tab; next and previous reach
/// the page's `mediaSession` handlers and are enabled only when it has
/// them. With no such tab Now Playing is cleared and the commands are
/// disabled. WebKit tabs are left out: WebKit publishes its pages' media
/// itself, from its GPU process.
final class BrowserNowPlaying {
    nonisolated enum Command: String, Sendable {
        case play, pause, toggle, next, previous
    }

    nonisolated struct Session: Equatable, Sendable {
        var tab: BrowserTabID
        var media: BrowserMediaState
    }

    private weak var services: AppServices?
    private var observation: Task<Void, Never>?
    private var registered = false
    /// The tab Now Playing shows.
    private(set) var current: Session?
    /// The current tab's artwork, once loaded.
    private var artwork: (url: URL, artwork: MPMediaItemArtwork?)?

    func follow(_ services: AppServices?) {
        self.services = services
        observation?.cancel()
        guard let services else {
            current = nil
            publish()
            return
        }
        register()
        observation = Task { [weak self, weak services] in
            for await sessions in ObservationStream({ [weak services] in services.map(Self.sessions) ?? [] }) {
                self?.update(sessions)
            }
        }
    }

    /// Runs a media key's command on the current tab; false without one.
    @discardableResult
    func perform(_ command: Command) -> Bool {
        guard let current, let tab = browserTab(current.tab) else { return false }
        let media: BrowserMediaCommand = switch command {
        case .play: .play
        case .pause: .pause
        case .toggle: .playPause
        case .next: .nextTrack
        case .previous: .previousTrack
        }
        Task { await tab.media(media) }
        return true
    }

    private static func sessions(_ services: AppServices) -> [Session] {
        services.cache.pageRequests.media.sessions(in: services.cache)
            .filter { $0.entry.tab is CEFTab }
            .map { Session(tab: $0.entry.tab.id, media: $0.media) }
    }

    private func browserTab(_ id: BrowserTabID) -> (any BrowserTab)? {
        services?.cache.browsers.values.first { $0.tab.id == id }?.tab
    }

    private func update(_ sessions: [Session]) {
        let shown = current.flatMap { current in sessions.first { $0.tab == current.tab } }
        // The shown tab keeps Now Playing while it plays; another takes it only by playing aloud.
        let next = (shown?.media.isAudible == true ? shown : nil) ?? sessions.first { $0.media.isAudible }
            ?? shown ?? sessions.first { $0.media.isPlaying }
        guard next != current else { return }
        current = next
        publish()
    }

    private func publish() {
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        guard let current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            for command in [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
                            commands.nextTrackCommand, commands.previousTrackCommand] {
                command.isEnabled = false
            }
            artwork = nil
            return
        }
        let media = current.media
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: media.title,
            MPNowPlayingInfoPropertyPlaybackRate: media.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: (media.isVideo ? MPNowPlayingInfoMediaType.video : .audio).rawValue,
        ]
        if !media.artist.isEmpty { info[MPMediaItemPropertyArtist] = media.artist }
        if !media.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = media.album }
        if let artwork, artwork.url == media.artworkURL, let image = artwork.artwork { info[MPMediaItemPropertyArtwork] = image }
        center.nowPlayingInfo = info
        center.playbackState = media.isPlaying ? .playing : .paused
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = media.actions.contains(.nexttrack)
        commands.previousTrackCommand.isEnabled = media.actions.contains(.previoustrack)
        loadArtwork(media.artworkURL, tab: current.tab)
    }

    /// Loads the page's artwork through its tab (its cookies, its proxy).
    private func loadArtwork(_ url: URL?, tab id: BrowserTabID) {
        guard artwork?.url != url else { return }
        guard let url, let tab = browserTab(id) else {
            artwork = nil
            return
        }
        artwork = (url, nil)
        Task { [weak self] in
            let image = await tab.fetchFavicon(url)
            guard let self, self.artwork?.url == url else { return }
            guard let image else {
                // Not loaded (the tab closed, the fetch failed): a later publish tries again.
                self.artwork = nil
                return
            }
            // MediaPlayer asks for the image off the main thread.
            // crash-allow: the image is never mutated after the fetch; MediaPlayer only reads it to draw.
            nonisolated(unsafe) let shown = image
            self.artwork = (url, MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in shown })
            self.publish()
        }
    }

    /// The media keys and Control Center's buttons. MediaPlayer may call
    /// the handlers off the main thread; they hop to it.
    private func register() {
        guard !registered else { return }
        registered = true
        let commands = MPRemoteCommandCenter.shared()
        let targets: [(MPRemoteCommand, Command)] = [
            (commands.playCommand, .play), (commands.pauseCommand, .pause), (commands.togglePlayPauseCommand, .toggle),
            (commands.nextTrackCommand, .next), (commands.previousTrackCommand, .previous),
        ]
        for (remote, command) in targets {
            remote.isEnabled = false
            remote.addTarget { @Sendable [weak self] _ in
                let owner = self
                Task { @MainActor in owner?.perform(command) }
                return .success
            }
        }
    }
}

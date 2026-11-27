import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextNowPlaying
import CmuxNextSidebar
import MediaPlayer

/// The playing Chromium tab in macOS Now Playing (Control Center, the lock
/// screen) and on the media keys (cx-6qwm.3), from the media hub's
/// sessions: an audible playing tab, else the tab shown so far while it
/// stays (paused or muted), else a muted playing one. Play, pause and
/// play/pause run the hub's play/pause on that tab; next and previous reach
/// the page's `mediaSession` handlers and are enabled only when it has
/// them. With no such tab Now Playing is cleared and the commands are
/// disabled. WebKit tabs are left out: WebKit publishes its pages' media
/// itself, from its GPU process. cmux's own music player (cx-imt2i) takes
/// Now Playing and the keys by the card's rule (`NowPlayingSources.playerHolds`);
/// turning `labs.previewFeatures` off stops it.
final class BrowserNowPlaying {
    nonisolated enum Command: String, Sendable {
        case play, pause, toggle, next, previous
    }

    typealias Session = NowPlayingSession

    private weak var services: AppServices?
    private var observation: Task<Void, Never>?
    private var registered = false
    /// The tab Now Playing shows.
    private(set) var current: Session?
    /// The music player's state, and whether it holds Now Playing over `current`.
    private var music: SidebarNowPlaying?
    /// The music player's artwork as decoded for Now Playing.
    private var musicArtwork: (data: Data, artwork: MPMediaItemArtwork)?
    private var musicHolds: Bool { NowPlayingSources.playerHolds(music, tabPlaying: current?.media.isPlaying == true) }
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
            for await (sessions, music, preview) in ObservationStream({ [weak services] in
                services.map { (Self.sessions($0), $0.cache.pageRequests.music.nowPlaying, $0.settings?.snapshot.previewFeatures == true) }
                    ?? ([], nil, false)
            }) {
                if !preview, music != nil { services?.cache.pageRequests.music.stop() }
                self?.update(sessions, music: preview ? music : nil)
            }
        }
    }

    /// Runs a media key's command on the current tab; false without one.
    @discardableResult
    func perform(_ command: Command) -> Bool {
        if musicHolds, let player = services?.cache.pageRequests.music {
            switch command {
            case .play: player.resume()
            case .pause: player.pause()
            case .toggle: player.perform(.playPause)
            case .next: player.perform(.next)
            case .previous: player.perform(.previous)
            }
            return true
        }
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

    private func update(_ sessions: [Session], music: SidebarNowPlaying?) {
        let next = Session.pick(after: current, from: sessions)
        guard next != current || music != self.music else { return }
        current = next
        self.music = music
        publish()
    }

    private func publish() {
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        if musicHolds, let music { return publish(music, center: center, commands: commands) }
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

    /// The music player's song: its title, artist, artwork and position, with the keys on it.
    private func publish(_ music: SidebarNowPlaying, center: MPNowPlayingInfoCenter, commands: MPRemoteCommandCenter) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: music.title,
            MPNowPlayingInfoPropertyPlaybackRate: music.isPlaying ? music.rate : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: music.position == nil,
        ]
        if !music.artist.isEmpty { info[MPMediaItemPropertyArtist] = music.artist }
        if let duration = music.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let position = music.position(at: Date()) { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position }
        if let data = music.artwork, musicArtwork?.data != data, let image = NSImage(data: data) {
            // crash-allow: the image is never mutated after decoding; MediaPlayer only reads it to draw.
            nonisolated(unsafe) let shown = image
            musicArtwork = (data, MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in shown })
        }
        if let data = music.artwork, let cached = musicArtwork, cached.data == data { info[MPMediaItemPropertyArtwork] = cached.artwork }
        center.nowPlayingInfo = info
        center.playbackState = music.isPlaying ? .playing : .paused
        for command in [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand, commands.previousTrackCommand] {
            command.isEnabled = true
        }
        commands.nextTrackCommand.isEnabled = music.canNext
        artwork = nil
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

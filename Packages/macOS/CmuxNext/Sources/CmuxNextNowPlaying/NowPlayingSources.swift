public import CmuxNextSidebar

/// Who holds Now Playing (cx-imt2i): cmux's player while it plays, else a browser tab playing
/// aloud, else another app that plays (Spotify, Music: `system`), else a paused player (it stays
/// until stopped), else the tabs' pick, paused or not, else another app's paused track.
/// Other apps take part only while ``otherApps`` says so (`sidebar.nowPlaying.otherApps`, off by
/// default): off, macOS Now Playing is not read, so another browser's audio never shows.
/// The sidebar card shows this source and its controls run on whichever it shows; the media keys
/// and Control Center follow the player-or-tab part of the rule (`BrowserNowPlaying`).
public final class NowPlayingSources: NowPlayingSource {
    public let player: MusicPlayer
    public let tabs: any NowPlayingSource
    public let system: (any NowPlayingSource)?
    /// Whether `system` (other apps) takes part; read while observing, so a change reaches the card.
    private let otherApps: @MainActor () -> Bool

    /// - Parameter otherApps: whether `system` takes part (the App reads `sidebar.nowPlaying.otherApps`).
    public init(player: MusicPlayer, tabs: any NowPlayingSource, system: (any NowPlayingSource)? = nil,
                otherApps: @escaping @MainActor () -> Bool = { false }) {
        self.player = player
        self.tabs = tabs
        self.system = system
        self.otherApps = otherApps
    }

    /// Whether the player holds Now Playing over the tabs' pick, which plays or not.
    public static func playerHolds(_ player: SidebarNowPlaying?, tabPlaying: Bool) -> Bool {
        guard let player else { return false }
        return player.isPlaying || !tabPlaying
    }

    /// The first of `shown` (in the sources' order) that plays, else the first there is.
    public static func pick(_ shown: [SidebarNowPlaying?]) -> Int? {
        shown.firstIndex { $0?.isPlaying == true } ?? shown.firstIndex { $0 != nil }
    }

    private var sources: [any NowPlayingSource] {
        let sources: [any NowPlayingSource] = [player, tabs]
        guard let system, otherApps() else { return sources }
        return sources + [system]
    }

    private var holder: (any NowPlayingSource, SidebarNowPlaying)? {
        let sources = sources, shown = sources.map(\.nowPlaying)
        guard let index = Self.pick(shown), let nowPlaying = shown[index] else { return nil }
        return (sources[index], nowPlaying)
    }

    public var nowPlaying: SidebarNowPlaying? { holder?.1 }

    public func run(_ on: Bool) {
        system?.run(on && otherApps())
    }

    public func perform(_ command: SidebarNowPlayingCommand) {
        holder?.0.perform(command)
    }
}

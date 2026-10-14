public import CmuxNextSidebar

/// Who holds Now Playing (cx-imt2i): cmux's player while it plays, else a browser tab playing
/// aloud, else a paused player (it stays until stopped), else the tabs' pick, paused or not.
/// The sidebar card shows this source and its controls run on whichever it shows; the media keys
/// and Control Center follow the same rule (`BrowserNowPlaying`).
public final class NowPlayingSources: NowPlayingSource {
    public let player: MusicPlayer
    public let tabs: any NowPlayingSource

    public init(player: MusicPlayer, tabs: any NowPlayingSource) {
        self.player = player
        self.tabs = tabs
    }

    /// Whether the player holds Now Playing over the tabs' pick, which plays or not.
    public static func playerHolds(_ player: SidebarNowPlaying?, tabPlaying: Bool) -> Bool {
        guard let player else { return false }
        return player.isPlaying || !tabPlaying
    }

    public var nowPlaying: SidebarNowPlaying? {
        let shown = player.nowPlaying, tab = tabs.nowPlaying
        return Self.playerHolds(shown, tabPlaying: tab?.isPlaying == true) ? shown : tab
    }

    public func perform(_ command: SidebarNowPlayingCommand) {
        if Self.playerHolds(player.nowPlaying, tabPlaying: tabs.nowPlaying?.isPlaying == true) {
            player.perform(command)
        } else {
            tabs.perform(command)
        }
    }
}

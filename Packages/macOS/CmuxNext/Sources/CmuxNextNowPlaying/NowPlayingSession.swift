public import CmuxNextBrowser

/// A browser tab that reports media, and how Now Playing picks among them:
/// macOS Now Playing (`BrowserNowPlaying`) and the sidebar's card
/// (`BrowserTabsNowPlaying`) pick the same way.
public nonisolated struct NowPlayingSession: Equatable, Sendable {
    public var tab: BrowserTabID
    public var media: BrowserMediaState

    public init(tab: BrowserTabID, media: BrowserMediaState) {
        self.tab = tab
        self.media = media
    }

    /// The session Now Playing shows after `current`: the shown tab keeps it
    /// while it plays; another takes it only by playing aloud.
    public static func pick(after current: NowPlayingSession?, from sessions: [NowPlayingSession]) -> NowPlayingSession? {
        let shown = current.flatMap { current in sessions.first { $0.tab == current.tab } }
        return (shown?.media.isAudible == true ? shown : nil) ?? sessions.first { $0.media.isAudible }
            ?? shown ?? sessions.first { $0.media.isPlaying }
    }
}

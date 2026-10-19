import CmuxNextCompat
public import CmuxNextSidebar

/// What the sidebar's Now Playing card (cx-ouoxo) shows and controls: the
/// playing cmux browser tab today (`BrowserTabsNowPlaying`); system Now
/// Playing would be another source. Reading `nowPlaying` while observing
/// tracks it.
@MainActor
public protocol NowPlayingSource: AnyObject {
    var nowPlaying: SidebarNowPlaying? { get }
    func perform(_ command: SidebarNowPlayingCommand)
}

extension NowPlayingSource {
    /// Runs the card's control; any other intent is not the card's.
    public func handle(_ intent: SidebarIntent) {
        guard case .nowPlaying(let command) = intent else { return }
        perform(command)
    }
}

extension SidebarModel {
    /// Shows `source` on the Now Playing card while `enabled` (the App passes
    /// `sidebar.nowPlaying.enabled`, on by default).
    public func followNowPlaying(_ source: any NowPlayingSource, enabled: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
        Task { [weak self] in
            for await nowPlaying in ObservationStream({ enabled() ? source.nowPlaying : nil }) {
                guard let self else { return }
                if self.nowPlaying != nowPlaying { self.nowPlaying = nowPlaying }
            }
        }
    }
}

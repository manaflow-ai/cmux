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
    /// Keeps the source reading while the card is on (another app's Now Playing streams only
    /// then); most sources read nothing of their own and ignore it.
    func run(_ on: Bool)
}

extension NowPlayingSource {
    public func run(_ on: Bool) {}
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
    /// `sidebar.nowPlaying.enabled`, off by default) and `dismissal` does not hide it.
    /// The source runs while `enabled` (`NowPlayingSource.run`), and the New Tab page's player
    /// shows the same track (`NewTabNowPlaying`), hidden card or not.
    public func followNowPlaying(_ source: any NowPlayingSource, dismissal: NowPlayingCardDismissal? = nil,
                                 enabled: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
        Task { [weak self] in
            // The hide state is read with the source, so a Hide or a Show reaches the card at once.
            for await (followed, _) in ObservationStream({
                (enabled() ? NowPlayingFollowed.on(source.nowPlaying) : .off, dismissal.map { [$0.hiddenMedia ?? "", "\($0.hiddenUntilRelaunch)"] })
            }) {
                guard let self else { return }
                source.run(followed != .off)
                let card = dismissal.map { $0.card(for: followed.nowPlaying, from: source) } ?? followed.nowPlaying
                if self.nowPlaying != card { self.nowPlaying = card }
                NewTabNowPlaying.show(followed.nowPlaying, from: source)
            }
        }
    }
}

/// What the card follows: nothing while it is off, else what plays (nil while nothing does).
nonisolated enum NowPlayingFollowed: Equatable, Sendable {
    case off
    case on(SidebarNowPlaying?)

    var nowPlaying: SidebarNowPlaying? {
        if case .on(let nowPlaying) = self { nowPlaying } else { nil }
    }
}

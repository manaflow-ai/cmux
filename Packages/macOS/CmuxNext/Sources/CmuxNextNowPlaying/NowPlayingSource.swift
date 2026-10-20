public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextSettings
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
    /// Shows `source` on the Now Playing card while `sidebar.nowPlaying.enabled` is on (on by
    /// default), and on the New Tab page while `tabs.newTabNowPlaying` is on too; the page's menu
    /// writes that key and opens its row in Settings through `registry` (`NewTabNowPlaying.page`).
    public func followNowPlaying(_ source: any NowPlayingSource, settings: @escaping @MainActor () -> SettingsController?,
                                 registry: ActionRegistry?) -> Task<Void, Never> {
        NewTabNowPlaying.page = NewTabNowPlaying.liveActions(settings: settings, registry: registry)
        return followNowPlaying(source, enabled: { settings()?.snapshot.nowPlaying.enabled ?? NowPlayingSettings.enabledDefault },
                                onNewTab: { settings()?.snapshot.nowPlaying.newTab ?? NowPlayingSettings.newTabDefault })
    }

    /// Shows `source` on the Now Playing card while `enabled`, and on the New Tab page's player
    /// (`NewTabNowPlaying`) while `onNewTab` is true too: off there, the page gets nil, so it draws
    /// no player and keeps no space. The source runs while `enabled` (`NowPlayingSource.run`).
    public func followNowPlaying(_ source: any NowPlayingSource, enabled: @escaping @MainActor () -> Bool,
                                 onNewTab: @escaping @MainActor () -> Bool = { true }) -> Task<Void, Never> {
        Task { [weak self] in
            for await followed in ObservationStream({ NowPlayingFollowed(enabled() ? .on(source.nowPlaying) : .off, newTab: onNewTab()) }) {
                guard let self else { return }
                source.run(followed.card != .off)
                if self.nowPlaying != followed.card.nowPlaying { self.nowPlaying = followed.card.nowPlaying }
                NewTabNowPlaying.show(followed.newTab ? followed.card.nowPlaying : nil, from: source)
            }
        }
    }
}

/// What the card follows (nothing while it is off, else what plays, nil while nothing does), and
/// whether the New Tab page shows it too.
nonisolated struct NowPlayingFollowed: Equatable, Sendable {
    var card: Card
    var newTab: Bool

    init(_ card: Card, newTab: Bool) {
        self.card = card
        self.newTab = newTab
    }

    nonisolated enum Card: Equatable, Sendable {
        case off
        case on(SidebarNowPlaying?)

        var nowPlaying: SidebarNowPlaying? {
            if case .on(let nowPlaying) = self { nowPlaying } else { nil }
        }
    }
}

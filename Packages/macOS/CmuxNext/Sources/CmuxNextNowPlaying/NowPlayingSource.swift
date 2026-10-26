public import CmuxNextActions
public import CmuxNextAgentPane
import CmuxNextCompat
public import CmuxNextSettings
public import CmuxNextSidebar
public import CmuxNextWakeups

/// What the sidebar's Now Playing card (cx-ouoxo) shows and controls: the
/// playing cmux browser tab today (`BrowserTabsNowPlaying`); system Now
/// Playing would be another source. Reading `nowPlaying` while observing
/// tracks it.
@MainActor
public protocol NowPlayingSource: AnyObject {
    var nowPlaying: SidebarNowPlaying? { get }
    func perform(_ command: SidebarNowPlayingCommand)
    /// Keeps the source reading while a surface shows it (another app's Now Playing streams only
    /// then); most sources read nothing of their own and ignore it.
    func run(_ need: NowPlayingNeed)
}

extension NowPlayingSource {
    public func run(_ need: NowPlayingNeed) {}
}

/// What the Now Playing surfaces need from a source that reads (`NowPlayingSource.run`).
public nonisolated enum NowPlayingNeed: Equatable, Sendable {
    /// No setting shows Now Playing (the card and the New Tab player off, or other apps off for
    /// macOS Now Playing): stop reading now.
    case off
    /// A setting shows Now Playing but no surface does (the card hidden until relaunch and the New
    /// Tab player off): reading may go on a while, for a surface that shows it again.
    case idle
    /// A surface shows what plays.
    case shown

    /// The need of the card (`card`: its setting is on, `cardHidden`: put away until relaunch) and
    /// the New Tab player (`newTab`: its setting is on). A card hidden for one track still needs
    /// what plays: other media brings it back.
    public init(card: Bool, cardHidden: Bool, newTab: Bool) {
        self = newTab || (card && !cardHidden) ? .shown : card ? .idle : .off
    }
}

extension NowPlayingSource {
    /// Runs the card's control; any other intent is not the card's.
    public func handle(_ intent: SidebarIntent) {
        guard case .nowPlaying(let command) = intent else { return }
        perform(command)
    }
}

extension SidebarModel {
    /// Shows `source` on the Now Playing card while `sidebar.nowPlaying.enabled` is on (off by
    /// default) and `dismissal` does not hide it, and on the New Tab page while
    /// `tabs.newTabNowPlaying` is on (off by default), hidden card or not; the page's menu writes
    /// that key and opens its row in Settings through `registry` (`NewTabNowPlaying.page`).
    public func followNowPlaying(_ source: any NowPlayingSource, dismissal: NowPlayingCardDismissal? = nil,
                                 settings: @escaping @MainActor () -> SettingsController?,
                                 registry: ActionRegistry?, queries: WorkspaceQueries?) -> Task<Void, Never> {
        NewTabNowPlaying.page = NewTabNowPlaying.liveActions(settings: settings, registry: registry, queries: queries)
        return followNowPlaying(source, dismissal: dismissal,
                                enabled: { settings()?.snapshot.nowPlaying.enabled ?? NowPlayingSettings.enabledDefault },
                                onNewTab: { settings()?.snapshot.nowPlaying.newTab ?? NowPlayingSettings.newTabDefault })
    }

    /// Shows `source` on the Now Playing card while `enabled` and `dismissal` does not hide it,
    /// and on the New Tab page's player (`NewTabNowPlaying`) while `onNewTab`, each on its own:
    /// off on the New Tab page, the page gets nil, so it draws no player and keeps no space. The
    /// source runs while either shows it (`NowPlayingSource.run`, ``NowPlayingNeed``); a card put
    /// away until relaunch lets it idle, and with both settings off nothing reads what plays.
    public func followNowPlaying(_ source: any NowPlayingSource, dismissal: NowPlayingCardDismissal? = nil,
                                 enabled: @escaping @MainActor () -> Bool,
                                 onNewTab: @escaping @MainActor () -> Bool = { false },
                                 player: AgentPaneNowPlaying = .shared) -> Task<Void, Never> {
        Task { [weak self] in
            // The hide state is read with the source, so a Hide or a Show reaches the card at once.
            for await (followed, _) in ObservationStream({
                (NowPlayingFollowed(card: enabled(), newTab: onNewTab(), source: source),
                 dismissal.map { [$0.hiddenMedia ?? "", "\($0.hiddenUntilRelaunch)"] })
            }) {
                guard let self else { return }
                source.run(NowPlayingNeed(card: followed.card, cardHidden: dismissal?.hiddenUntilRelaunch == true,
                                          newTab: followed.newTab))
                let offered = followed.card ? followed.nowPlaying : nil
                let card = dismissal.map { $0.card(for: offered, from: source) } ?? offered
                if self.nowPlaying != card { self.nowPlaying = card }
                NewTabNowPlaying.show(followed.newTab ? followed.nowPlaying : nil, from: source, to: player)
            }
        }
    }
}

/// Where Now Playing shows (the sidebar card, the New Tab page), and what plays while either does
/// (nil while nothing does, or while neither shows it: the source is not read then).
nonisolated struct NowPlayingFollowed: Equatable, Sendable {
    var card: Bool
    var newTab: Bool
    var nowPlaying: SidebarNowPlaying?

    @MainActor init(card: Bool, newTab: Bool, source: any NowPlayingSource) {
        self.card = card
        self.newTab = newTab
        nowPlaying = card || newTab ? source.nowPlaying : nil
    }
}

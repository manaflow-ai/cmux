public import Observation
public import CmuxNextSidebar

/// Whether the sidebar's Now Playing card is put away (u2437): its x and its
/// menu's Hide hide it for the media it shows until other media starts; Hide
/// Until Relaunch hides it for this run of the app. One per app, shared by
/// every window's sidebar (`SidebarModel.followNowPlaying`). Never Show Media
/// Card is the `sidebar.nowPlaying.enabled` setting, not this. It also knows
/// the source the card shows, so the card's Play/Pause runs on that source.
@MainActor @Observable
public final class NowPlayingCardDismissal {
    /// The ``SidebarNowPlaying/mediaKey`` the card is hidden for, nil when none is.
    public private(set) var hiddenMedia: String?
    /// The card stays hidden until the app quits.
    public private(set) var hiddenUntilRelaunch = false
    /// What the card shows now (the last media a follow offered and did not hide), for Hide.
    public private(set) var shown: SidebarNowPlaying?
    /// The source the card shows (the last follow's), for Play/Pause.
    @ObservationIgnored public private(set) weak var source: (any NowPlayingSource)?

    public init() {}

    /// What the card shows for `offered`: nothing while it is hidden. Other media than the hidden
    /// one ends that hide, so the card comes back for it (and stays back for the old one).
    public func card(for offered: SidebarNowPlaying?, from source: (any NowPlayingSource)? = nil) -> SidebarNowPlaying? {
        if let source { self.source = source }
        if let hidden = hiddenMedia, let offered, offered.mediaKey != hidden { hiddenMedia = nil }
        let card = hiddenUntilRelaunch || offered.map { $0.mediaKey == hiddenMedia } == true ? nil : offered
        if shown != card { shown = card }
        return card
    }

    /// Hides the card for the media it shows. Returns false when no card shows.
    @discardableResult
    public func hideShown() -> Bool {
        guard let shown else { return false }
        hiddenMedia = shown.mediaKey
        self.shown = nil
        return true
    }

    /// Hides the card until the app quits.
    public func hideUntilRelaunch() {
        hiddenUntilRelaunch = true
        shown = nil
    }

    /// Ends every hide (Show Media Card).
    public func reset() {
        hiddenMedia = nil
        hiddenUntilRelaunch = false
    }
}

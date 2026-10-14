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
    /// `labs.previewFeatures`: a preview feature until it ships).
    public func followNowPlaying(_ source: any NowPlayingSource, enabled: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
        Task { [weak self] in
            for await nowPlaying in ObservationStream({ enabled() ? source.nowPlaying : nil }) {
                guard let self else { return }
                if self.nowPlaying != nowPlaying { self.nowPlaying = nowPlaying }
            }
        }
    }
}

extension Task where Success == Void, Failure == Never {
    /// A task that waits on this one and cancels both it and `other` when cancelled.
    public func cancelling(_ other: Task<Void, Never>) -> Task<Void, Never> {
        Task { await withTaskCancellationHandler { await self.value } onCancel: { self.cancel(); other.cancel() } }
    }
}

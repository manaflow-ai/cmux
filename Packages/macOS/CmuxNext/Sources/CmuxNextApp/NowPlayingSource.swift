import CmuxNextCompat
import CmuxNextSidebar
import Foundation

/// What the sidebar's Now Playing card shows and controls (cx-ouoxo): the
/// playing cmux browser tab today (`BrowserTabsNowPlaying`); system Now
/// Playing would be another source. Reading `nowPlaying` while observing
/// tracks it.
@MainActor
protocol NowPlayingSource: AnyObject {
    var nowPlaying: SidebarNowPlaying? { get }
    func perform(_ command: SidebarNowPlayingCommand)
}

/// Feeds a Now Playing source to the sidebar's card while `enabled`
/// (`labs.previewFeatures`: a preview feature until it ships), and sends the
/// card's controls back to it.
@MainActor
enum SidebarNowPlayingFeed {
    static func start(model: SidebarModel, source: any NowPlayingSource, enabled: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
        Task {
            for await nowPlaying in ObservationStream({ enabled() ? source.nowPlaying : nil }) {
                if model.nowPlaying != nowPlaying { model.nowPlaying = nowPlaying }
            }
        }
    }

    /// The browser tabs' Now Playing for a window's sidebar, while `labs.previewFeatures` is on.
    static func start(model: SidebarModel, services: AppServices) -> Task<Void, Never> {
        start(model: model, source: services.cache.pageRequests.sidebarNowPlaying,
              enabled: { [weak services] in services?.settings?.snapshot.previewFeatures == true })
    }

    static func handle(_ intent: SidebarIntent, source: any NowPlayingSource) {
        guard case .nowPlaying(let command) = intent else { return }
        source.perform(command)
    }
}

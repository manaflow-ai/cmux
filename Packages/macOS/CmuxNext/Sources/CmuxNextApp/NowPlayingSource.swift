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
        Task {}
    }

    static func handle(_ intent: SidebarIntent, source: any NowPlayingSource) {

    }
}

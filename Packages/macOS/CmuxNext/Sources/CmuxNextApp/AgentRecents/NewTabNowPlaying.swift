import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextNowPlaying
import CmuxNextSidebar
import Foundation

/// The New Tab page's Now Playing player: what the sidebar card shows (the
/// card's sources: the built-in player, a browser tab, another app), pushed to
/// every agent page as it changes while `sidebar.nowPlaying.enabled` is on,
/// and the page's controls run on that source. The artwork is encoded as a
/// data URL once per image.
@MainActor
enum NewTabNowPlaying {
    static func wire(services: AppServices) {
        let sources = services.cache.pageRequests.sidebarSources
        let player = AgentPaneNowPlaying.shared
        player.onCommand = { [weak sources] command in sources?.perform(sidebarCommand(command)) }
        // task-owner: app-lifetime; event-driven (Observation on the card's sources and the setting)
        Task { [weak services] in
            var artwork: (data: Data, url: String)?
            for await shown in ObservationStream({ [weak services] in
                services?.settings?.snapshot.nowPlaying.enabled ?? false ? services?.cache.pageRequests.sidebarSources.nowPlaying : nil
            }) {
                guard services != nil else { return }
                if let data = shown?.artwork, artwork?.data != data {
                    artwork = (data, "data:image/png;base64," + data.base64EncodedString())
                }
                player.track = shown.map { track($0, artwork: $0.artwork == nil ? nil : artwork?.url) }
            }
        }
    }

    /// The card's track as the page draws it.
    static func track(_ shown: SidebarNowPlaying, artwork: String?) -> AgentPaneNowPlaying.Track {
        let labels = shown.labels
        return AgentPaneNowPlaying.Track(
            title: shown.title, artist: shown.artist, artwork: artwork, isPlaying: shown.isPlaying, position: shown.position,
            duration: shown.duration, rate: shown.rate, positionDate: shown.positionDate, canPrevious: shown.canPrevious,
            canNext: shown.canNext,
            labels: ["play": labels.play, "pause": labels.pause, "previous": labels.previous, "next": labels.next])
    }

    static func sidebarCommand(_ command: AgentPaneNowPlaying.Command) -> SidebarNowPlayingCommand {
        switch command {
        case .playPause: .playPause
        case .previous: .previous
        case .next: .next
        case .seek(let seconds): .seek(seconds)
        }
    }
}

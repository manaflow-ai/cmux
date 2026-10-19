import CmuxNextAgentPane
import CmuxNextSidebar
import Foundation

/// The New Tab page's Now Playing player: what the sidebar card shows, pushed to every agent page
/// (`AgentPaneNowPlaying`) as the card's follow sees it change (`followNowPlaying`), nil while the
/// card is off or nothing plays; the page's controls run on the card's sources. The artwork is
/// redrawn as a small PNG data URL once per image: cmux's own player hands over the file's embedded
/// art as is, and every track change goes to every agent page.
@MainActor
enum NewTabNowPlaying {
    /// The last artwork encoded, and its data URL (nil when the bytes are not an image).
    private static var artwork: (data: Data, url: String?)?
    /// The artwork's side in pixels: the page's 88pt slot at 2x.
    static let artworkSide = 176

    static func show(_ shown: SidebarNowPlaying?, from source: any NowPlayingSource) {
        let player = AgentPaneNowPlaying.shared
        player.onCommand = { [weak source] command in source?.perform(sidebarCommand(command)) }
        if let data = shown?.artwork, artwork?.data != data {
            artwork = (data, artworkURL(data))
        }
        player.track = shown.map { track($0, artwork: $0.artwork == nil ? nil : artwork?.url ?? nil) }
    }

    /// The image redrawn as an `artworkSide` PNG data URL, or nil when the bytes are not an image.
    static func artworkURL(_ data: Data) -> String? {
        SystemNowPlaying.png(data, side: artworkSide).map { "data:image/png;base64," + $0.base64EncodedString() }
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

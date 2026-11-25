public import CmuxNextSidebar
public import Foundation
import ImageIO
import UniformTypeIdentifiers

extension MediaAppOps {
    /// `media.get` and `media.control` over the Now Playing card's sources (the App passes
    /// `NowPlayingSources`): the track the card shows and its transport, whether the card or the
    /// New Tab player is on or not. Another app's Now Playing takes part only while
    /// `sidebar.nowPlaying.otherApps` is on and the card or the New Tab player reads it, as for the card.
    /// - Parameters:
    ///   - nowPlaying: What the card's sources play now, read at each call.
    ///   - perform: Runs a control on the card's sources.
    @MainActor public static func card(_ nowPlaying: @escaping @MainActor @Sendable () -> SidebarNowPlaying?,
                                       perform: @escaping @MainActor @Sendable (SidebarNowPlayingCommand) -> Void) -> MediaAppOps {
        let artwork = ArtworkURL()
        return MediaAppOps(track: {
            nowPlaying().map { Track(card: $0, artwork: artwork.url(for: $0.artwork)) }
        }, perform: { command in
            guard nowPlaying() != nil else { return false }
            perform(command.card)
            return true
        })
    }

    /// The artwork as a PNG data URL at most ``side`` pixels on its long edge, redrawn once per image:
    /// cmux's own player hands over a file's embedded art as is. Keeps the last image and its URL.
    @MainActor final class ArtworkURL {
        nonisolated static let side = 176
        private var last: (data: Data, url: String?)?

        func url(for data: Data?) -> String? {
            guard let data else { return nil }
            if let last, last.data == data { return last.url }
            let url = Self.png(data).map { "data:image/png;base64," + $0.base64EncodedString() }
            last = (data, url)
            return url
        }

        /// `data` decoded and drawn at most `side` pixels on its long edge, as PNG; nil when it is not an image.
        nonisolated static func png(_ data: Data) -> Data? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? out as Data : nil
        }
    }
}

extension MediaAppOps.Track {
    /// The card's track as `media.get` answers it, with `artwork` already a data URL.
    public init(card shown: SidebarNowPlaying, artwork: String?) {
        self.init(title: shown.title, artist: shown.artist, artwork: artwork, isPlaying: shown.isPlaying, position: shown.position,
                  duration: shown.duration, rate: shown.rate, positionDate: shown.positionDate, canPrevious: shown.canPrevious,
                  canNext: shown.canNext, source: shown.app?.name)
    }
}

extension MediaAppOps.Command {
    /// The card's control for this command.
    var card: SidebarNowPlayingCommand {
        switch self {
        case .playPause: .playPause
        case .previous: .previous
        case .next: .next
        case .seek(let seconds): .seek(seconds)
        }
    }
}

extension AppProviderChangeFeed {
    /// `media.changed` whenever what the card's sources play changes (another track, play or pause, a
    /// seek, new artwork), so an extension's player reads `media.get` again instead of polling.
    /// - Parameter nowPlaying: What the card's sources play now (observed).
    @MainActor public static func media(_ nowPlaying: @escaping @MainActor @Sendable () -> SidebarNowPlaying?) -> AppProviderChangeFeed {
        AppProviderChangeFeed(family: "media", value: nowPlaying)
    }
}

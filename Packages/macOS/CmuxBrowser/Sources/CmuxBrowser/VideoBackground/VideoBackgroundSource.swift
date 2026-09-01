public import Foundation

/// A parsed dynamic-video-background source.
///
/// The settings UI stores a free-form string (`terminal.videoBackground.source`);
/// this type turns that string into something the window layer can play:
/// a single YouTube video, a YouTube playlist, or a local video file.
/// Parsed YouTube identifiers are charset-validated so they are safe to
/// interpolate into the generated embed page.
public enum VideoBackgroundSource: Equatable, Sendable {
    /// A single YouTube video, looped forever.
    case youTubeVideo(id: String)

    /// A YouTube playlist, looped forever, advancing between entries.
    case youTubePlaylist(id: String)

    /// A local video file, looped forever via AVFoundation.
    case localFile(url: URL)

    /// YouTube hosts whose URLs are recognized as video/playlist sources.
    private static let youTubeHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com",
        "music.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com",
    ]

    /// File extensions accepted for the local-file fallback.
    private static let localVideoExtensions: Set<String> = ["mp4", "m4v", "mov"]

    /// Parses user-entered source text into a playable source.
    ///
    /// Accepted forms: YouTube watch/short-link/shorts/live/embed URLs,
    /// YouTube playlist URLs (a `list` query item wins over a `v` item so a
    /// "watch within playlist" link plays the whole playlist), raw video or
    /// playlist IDs, and local file paths or `file://` URLs with a video
    /// extension.
    ///
    /// - Parameter text: The raw setting value.
    /// - Returns: A parsed source, or `nil` when the text names nothing playable.
    public static func parse(_ text: String) -> VideoBackgroundSource? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let local = parseLocalFile(trimmed) { return local }
        if let url = URL(string: trimmed), let fromURL = parse(url: url) { return fromURL }
        if isValidPlaylistID(trimmed), hasKnownPlaylistPrefix(trimmed) { return .youTubePlaylist(id: trimmed) }
        if isValidVideoID(trimmed) { return .youTubeVideo(id: trimmed) }
        return nil
    }

    /// Whether a candidate matches YouTube's 11-character video ID shape.
    public static func isValidVideoID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy(Self.isIdentifierCharacter)
    }

    /// Whether a candidate is a plausible, interpolation-safe playlist ID.
    public static func isValidPlaylistID(_ id: String) -> Bool {
        (10...64).contains(id.count) && id.allSatisfy(Self.isIdentifierCharacter)
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
    }

    private static func hasKnownPlaylistPrefix(_ id: String) -> Bool {
        ["PL", "UU", "FL", "OLAK5uy_", "RDCLAK"].contains { id.hasPrefix($0) }
    }

    private static func parseLocalFile(_ text: String) -> VideoBackgroundSource? {
        let fileURL: URL?
        if text.lowercased().hasPrefix("file://") {
            fileURL = URL(string: text)
        } else if text.hasPrefix("/") || text.hasPrefix("~") {
            fileURL = URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        } else {
            fileURL = nil
        }
        guard let fileURL, fileURL.isFileURL,
              localVideoExtensions.contains(fileURL.pathExtension.lowercased()) else {
            return nil
        }
        return .localFile(url: fileURL)
    }

    private static func parse(url: URL) -> VideoBackgroundSource? {
        guard let host = url.host?.lowercased() else { return nil }

        if host == "youtu.be" {
            return parseYouTubePath(firstComponent: url.pathComponents.dropFirst().first, url: url)
        }
        guard youTubeHosts.contains(host) else { return nil }

        if let listID = queryValue(named: "list", in: url), isValidPlaylistID(listID) {
            return .youTubePlaylist(id: listID)
        }

        let components = url.pathComponents.dropFirst()
        switch components.first {
        case "watch":
            guard let videoID = queryValue(named: "v", in: url), isValidVideoID(videoID) else { return nil }
            return .youTubeVideo(id: videoID)
        case "shorts", "embed", "live", "v":
            return parseYouTubePath(firstComponent: components.dropFirst().first, url: url)
        default:
            return nil
        }
    }

    private static func parseYouTubePath(firstComponent: String?, url: URL) -> VideoBackgroundSource? {
        if let listID = queryValue(named: "list", in: url), isValidPlaylistID(listID) {
            return .youTubePlaylist(id: listID)
        }
        guard let videoID = firstComponent, isValidVideoID(videoID) else { return nil }
        return .youTubeVideo(id: videoID)
    }

    private static func queryValue(named name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}

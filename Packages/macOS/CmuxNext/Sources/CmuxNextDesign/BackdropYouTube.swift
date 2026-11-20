public import Foundation

/// A YouTube video as the wallpaper (Leo: "people can already play youtube videos in their
/// background right", then "yeah add youtube backgrounds too"), persisted as
///
///     youtube:<VIDEO_ID>[?start=<S>][&end=<E>][&quality=<Q>]
///
/// The 11-character video id; whole seconds `start` (0 by default) and `end` (none: to the end),
/// 0 <= start < end <= 86400; and `quality`, the player's height in pixels (1080 by default),
/// which bounds the stream YouTube sends. Parameters equal to their default are left out, in that
/// order. This type reads and writes only that canonical form: turning a pasted YouTube link into
/// it is the Rust side's (cmux-config), so Swift and Rust can never disagree on a link.
///
/// It plays in the YouTube embed (``BackdropYouTubeView``); the video's thumbnail is its poster
/// (``posterURL``), cached in Caches. Its title is YouTube's (oEmbed), the video id until known.
public nonisolated struct BackdropYouTube: Hashable, Sendable {
    /// The 11-character YouTube video id.
    public let videoID: String
    /// Where the loop starts, in whole seconds.
    public let start: Int
    /// Where the loop ends, in whole seconds; nil plays to the end of the video.
    public let end: Int?
    /// The player's height in pixels (``qualities``).
    public let quality: Int

    /// Whether the app offers YouTube wallpapers: the one switch, off until Leo decides how the
    /// embed may sit under panes, tint and blur. Off, no ``BackdropYouTubeView`` is made, no web
    /// view loads, no poster or title is fetched, the catalog lists none, a `youtube:` id draws no
    /// picture, and the Settings page's host lists say `youtube_wallpapers: false` (no Add tile).
    /// Tests turn it on through ``BackdropImageStore/offersYouTube`` and the catalog's `youtube:`.
    public static let isOffered = false
    /// The prefix of a persisted id.
    public static let idPrefix = "youtube:"
    /// The player heights a wallpaper may ask for.
    public static let qualities = [360, 480, 720, 1080, 1440, 2160]
    /// The player height when none is asked for.
    public static let defaultQuality = 1080
    /// The latest a loop may end: a day.
    public static let maximumSeconds = 86400

    /// A video, or nil when a part is out of range (an id that is not 11 of `[A-Za-z0-9_-]`, an
    /// end not after the start, a quality not in ``qualities``).
    public init?(videoID: String, start: Int = 0, end: Int? = nil, quality: Int = BackdropYouTube.defaultQuality) {
        guard Self.isVideoID(videoID), start >= 0, start < Self.maximumSeconds, Self.qualities.contains(quality) else { return nil }
        if let end, end <= start || end > Self.maximumSeconds { return nil }
        self.videoID = videoID
        self.start = start
        self.end = end
        self.quality = quality
    }

    /// The video a canonical id names; nil for any other string, a non-canonical spelling included
    /// (parameters out of order, repeated, unknown, or equal to their default).
    public init?(id: String) {
        guard id.hasPrefix(Self.idPrefix) else { return nil }
        let rest = id.dropFirst(Self.idPrefix.count)
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var start = 0, end: Int?, quality = Self.defaultQuality
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&", omittingEmptySubsequences: false) {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv.count == 2, let value = Self.wholeNumber(kv[1]) else { return nil }
                switch kv[0] {
                case "start": start = value
                case "end": end = value
                case "quality": quality = value
                default: return nil
                }
            }
        }
        guard let video = BackdropYouTube(videoID: String(parts[0]), start: start, end: end, quality: quality),
              video.id == id else { return nil }
        self = video
    }

    /// The canonical persisted id.
    public var id: String {
        var parameters: [String] = []
        if start != 0 { parameters.append("start=\(start)") }
        if let end { parameters.append("end=\(end)") }
        if quality != Self.defaultQuality { parameters.append("quality=\(quality)") }
        return Self.idPrefix + videoID + (parameters.isEmpty ? "" : "?" + parameters.joined(separator: "&"))
    }

    /// Whether `text` is a YouTube video id: 11 of `[A-Za-z0-9_-]`.
    public static func isVideoID(_ text: String) -> Bool {
        text.utf8.count == 11 && text.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }
    }

    /// Digits only, no sign, no leading zero but "0", at most six of them.
    private static func wholeNumber(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.count <= 6, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              text == "0" || !text.hasPrefix("0") else { return nil }
        return Int(text)
    }

    // MARK: Title and attribution

    /// The title until YouTube's is known: the video id. The picker shows YouTube's title from the
    /// library (``BackdropCatalog/youtubeTitles``, fetched once from oEmbed).
    public var title: String { videoID }

    /// The line under the title: "YouTube · <title>".
    public static func attribution(title: String) -> String {
        String(localized: "backdrop.youtube.attribution", defaultValue: "YouTube · %@", bundle: .module)
            .replacingOccurrences(of: "%@", with: title)
    }

    /// A title as read from YouTube: trimmed, at most 200 characters; nil when empty.
    static func cleanTitle(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return String(title.prefix(200))
    }

    /// YouTube's oEmbed answer for the video: its title.
    var oEmbedURL: URL? {
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
                                  URLQueryItem(name: "format", value: "json")]
        return components?.url
    }

    // MARK: Poster

    /// YouTube's thumbnail of the video (480x360, always there for a public video).
    public var posterRemoteURL: URL? { URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg") }

    /// The thumbnail kept in Caches: the picker's tile, and the poster under the player and while
    /// it is paused or another window plays it. Fetched once (``BackdropYouTubeDownloads``).
    public var posterURL: URL {
        Self.posterFolder.appendingPathComponent("\(videoID).jpg")
    }

    /// The folder the posters are kept in, beside the living wallpapers' stills.
    static let posterFolder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux-next", isDirectory: true)
            .appendingPathComponent("backdrop-youtube", isDirectory: true)
    }()

    // MARK: Player

    /// The player's layout size in points for a backing scale: 16:9 at `quality` pixels high, so
    /// YouTube (which picks the stream from the player's size) sends at most that.
    public func playerSize(backingScale: CGFloat) -> CGSize {
        let scale = max(backingScale, 1)
        let height = (CGFloat(quality) / scale).rounded()
        return CGSize(width: (height * 16 / 9).rounded(), height: height)
    }
}

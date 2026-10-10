public import Foundation

/// What a page plays now, as Edge's media hub shows it (cx-6qwm.2): the
/// `navigator.mediaSession` metadata when the page sets it, else the page
/// title, and the playing element's state. Both engines report it from the
/// same page script (`BrowserMediaState+Scripts`); nil when the page plays nothing.
public nonisolated struct BrowserMediaState: Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    /// The largest artwork the page lists, resolved against the page.
    public var artworkURL: URL?
    public var isPlaying: Bool
    /// Muted, or at volume 0.
    public var isMuted: Bool
    public var isVideo: Bool
    /// The reporting frame keeps the tab muted (`BrowserAudioMuting`).
    public var isTabMuted: Bool
    /// The `mediaSession` actions the page handles (`nexttrack`, ...).
    public var actions: Set<BrowserMediaAction>

    public init(title: String, artist: String = "", album: String = "", artworkURL: URL? = nil, isPlaying: Bool,
                isMuted: Bool = false, isVideo: Bool = false, isTabMuted: Bool = false, actions: Set<BrowserMediaAction> = []) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.isPlaying = isPlaying
        self.isMuted = isMuted
        self.isVideo = isVideo
        self.isTabMuted = isTabMuted
        self.actions = actions
    }

    /// Sound is coming out of the tab (the tab's speaker indicator).
    public var isAudible: Bool { isPlaying && !isMuted }

    /// The script's report: an object, or null when the page stopped
    /// playing. Nil for anything else.
    public static func report(_ body: Any?) -> BrowserMediaState?? {
        if body == nil || body is NSNull { return .some(nil) }
        guard let object = body as? [String: Any] else { return nil }
        func text(_ key: String, limit: Int = 512) -> String {
            String((object[key] as? String ?? "").prefix(limit))
        }
        let artwork = (object["artwork"] as? String).flatMap(URL.init(string:)).flatMap { url in
            url.scheme == "https" || url.scheme == "http" ? url : nil
        }
        let actions = (object["actions"] as? String ?? "").split(separator: ",").compactMap { BrowserMediaAction(rawValue: String($0)) }
        return .some(BrowserMediaState(
            title: text("title"), artist: text("artist"), album: text("album"), artworkURL: artwork,
            isPlaying: object["playing"] as? Bool ?? false, isMuted: object["muted"] as? Bool ?? false,
            isVideo: object["video"] as? Bool ?? false, isTabMuted: object["tabMuted"] as? Bool ?? false, actions: Set(actions)))
    }

    /// The Chromium binding's payload: the same report as JSON text.
    public static func report(json: String) -> BrowserMediaState?? {
        guard let data = json.data(using: .utf8), let body = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return report(body)
    }
}

/// A `navigator.mediaSession` action a page can handle.
public nonisolated enum BrowserMediaAction: String, CaseIterable, Hashable, Sendable {
    case play
    case pause
    case previoustrack
    case nexttrack
}

/// What the media hub asks a page to do.
public nonisolated enum BrowserMediaCommand: Hashable, Sendable {
    case playPause
    case previousTrack
    case nextTrack
    case toggleMute
    /// Mutes (true) or unmutes every media element of the page and its
    /// frames, now and as they play (the tab's mute).
    case muteTab(Bool)
}

/// A page whose tab can be muted (cx-d0d.24): Mute Tab keeps every frame's
/// media muted, across navigations, until Unmute. Pages built on the media
/// scripts (WebKit and Chromium) adopt it. Web Audio is not muted.
@MainActor
public protocol BrowserAudioMuting: AnyObject {
    func setAudioMuted(_ muted: Bool)
}

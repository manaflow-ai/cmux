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
    /// The page's video floats in Picture in Picture (Chromium's PiP window,
    /// WebKit's presentation mode); it plays on while the tab is hidden.
    public var isPictureInPicture: Bool
    /// The reporting frame keeps the tab muted (`BrowserAudioMuting`).
    public var isTabMuted: Bool
    /// The `mediaSession` actions the page handles (`nexttrack`, ...).
    public var actions: Set<BrowserMediaAction>
    /// The element's position in seconds when reported (`positionDate`);
    /// nil from a page that did not say.
    public var position: TimeInterval?
    /// The element's length in seconds; nil while unknown or for a live stream.
    public var duration: TimeInterval?
    /// The element's playback rate (1 is normal speed).
    public var rate: Double
    /// When `position` was read.
    public var positionDate: Date

    public init(title: String, artist: String = "", album: String = "", artworkURL: URL? = nil, isPlaying: Bool,
                isMuted: Bool = false, isVideo: Bool = false, isPictureInPicture: Bool = false, isTabMuted: Bool = false,
                actions: Set<BrowserMediaAction> = [], position: TimeInterval? = nil, duration: TimeInterval? = nil, rate: Double = 1,
                positionDate: Date = Date()) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.isPlaying = isPlaying
        self.isMuted = isMuted
        self.isVideo = isVideo
        self.isPictureInPicture = isPictureInPicture
        self.isTabMuted = isTabMuted
        self.actions = actions
        self.position = position
        self.duration = duration
        self.rate = rate
        self.positionDate = positionDate
    }

    /// Sound is coming out of the tab (the tab's speaker indicator).
    public var isAudible: Bool { isPlaying && !isMuted }

    /// The position at `date`: it moves on while playing, kept inside the length.
    public func position(at date: Date) -> TimeInterval? {
        guard let position else { return nil }
        let moved = isPlaying ? position + max(0, date.timeIntervalSince(positionDate)) * rate : position
        return min(max(0, moved), duration ?? .infinity)
    }

    /// The state a tab keeps after `report`: the earlier one when the report
    /// changes nothing but a position that moved on as expected (the page's
    /// heartbeat), so a playing tab does not change state every few seconds;
    /// else the report, whole (a pause, a resume or a speed change takes its
    /// own position and time).
    public static func settled(_ earlier: BrowserMediaState?, _ report: BrowserMediaState?) -> BrowserMediaState? {
        guard let earlier, let report else { return report }
        let onCourse = switch (earlier.position(at: report.positionDate), report.position) {
        case (nil, nil): true
        case let (expected?, reported?): abs(reported - expected) < 1.5
        default: false
        }
        var same = report
        same.position = earlier.position
        same.positionDate = earlier.positionDate
        return onCourse && same == earlier ? earlier : report
    }

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
        func seconds(_ key: String) -> TimeInterval? {
            (object[key] as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        return .some(BrowserMediaState(
            title: text("title"), artist: text("artist"), album: text("album"), artworkURL: artwork,
            isPlaying: object["playing"] as? Bool ?? false, isMuted: object["muted"] as? Bool ?? false,
            isVideo: object["video"] as? Bool ?? false, isPictureInPicture: object["pip"] as? Bool ?? false,
            isTabMuted: object["tabMuted"] as? Bool ?? false, actions: Set(actions),
            position: seconds("position"), duration: seconds("duration").flatMap { $0 > 0 ? $0 : nil },
            rate: seconds("rate").flatMap { $0 > 0 ? $0 : nil } ?? 1))
    }

    /// One frame's message from the observer: `{frame, report}`, the id its observer picked
    /// for its document and that frame's report (``report(_:)``). Nil for anything else.
    package static func frameReport(_ body: Any?) -> (frame: String, media: BrowserMediaState?)? {
        guard let object = body as? [String: Any], let frame = object["frame"] as? String,
              let media = report(object["report"]) else { return nil }
        return (String(frame.prefix(64)), media)
    }

    /// ``frameReport(_:)`` from JSON (Chromium's binding payload).
    package static func frameReport(json: String) -> (frame: String, media: BrowserMediaState?)? {
        guard let data = json.data(using: .utf8), let body = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return frameReport(body)
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
    /// Plays or pauses whatever the page shows, as the media keys' Play and
    /// Pause do (no toggle from a report that may be stale).
    case play
    case pause
    case previousTrack
    case nextTrack
    case toggleMute
    /// Moves the playing element to this many seconds in.
    case seek(TimeInterval)
    /// Mutes (true) or unmutes every media element of the page and its
    /// frames, now and as they play (the tab's mute).
    case muteTab(Bool)
    /// Floats the page's video in Picture in Picture, or brings it back
    /// into the tab when one floats (``BrowserPictureInPicture``).
    case pictureInPicture
}

/// What ``BrowserMediaCommand/pictureInPicture`` did in the page.
public nonisolated enum BrowserPictureInPicture: String, Sendable {
    /// A video started to float.
    case entered
    /// The floating video went back into its tab.
    case exited
    /// The page has no video to float.
    case noVideo
    /// The page's video may not float (`disablePictureInPicture`, an engine without it).
    case unsupported
}

/// A page whose tab can be muted (cx-d0d.24): Mute Tab keeps the media of
/// the page and its frames muted, across navigations, until Unmute. Pages
/// built on the media scripts (WebKit and Chromium) adopt it. It sets the
/// elements' `muted`, which the page sees. Not muted: Web Audio, media in
/// shadow roots, Chromium's out-of-process frames, and a new document's
/// first moments, until its report brings the mute back.
@MainActor
public protocol BrowserAudioMuting: AnyObject {
    func setAudioMuted(_ muted: Bool)
}

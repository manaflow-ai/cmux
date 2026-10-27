import CmuxNextCompat
import CmuxNextSettings
public import Foundation

/// The Now Playing player on the New Tab page: what plays (the sidebar card's sources,
/// `NowPlayingSources`) for every agent page, and its controls back to them. App-wide like Now
/// Playing itself: CmuxNextNowPlaying's `NewTabNowPlaying` sets ``track`` and ``onCommand``; each page gets the track at load and
/// handshake and again on every change. Not an AgentPaneView extension: that type is at its size limit.
@MainActor
public final class AgentPaneNowPlaying {
    public static let shared = AgentPaneNowPlaying()

    /// One player; the App uses `shared`, a test its own (its pages are only the views it pushes to).
    init() {}

    /// What plays, nil while nothing does or the player is hidden (`tabs.newTabNowPlaying`).
    public var track: Track? {
        didSet {
            guard track != oldValue else { return }
            for view in views.allObjects { send(to: view) }
        }
    }
    /// Runs a page's control (`nowPlaying.command`) on what plays.
    public var onCommand: ((Command) -> Void)?
    /// The pages pushed so far, held weakly, for the pushes on a change.
    private let views = NSHashTable<AgentPaneView>.weakObjects()

    /// One track as the page draws it.
    public nonisolated struct Track: Hashable, Sendable {
        public var title: String
        public var artist: String
        /// The artwork as a `data:image/png;base64,` URL (a cmux page's CSP allows `img-src data:` only).
        public var artwork: String?
        public var isPlaying: Bool
        /// The position in seconds at `positionDate`; nil without one (a live stream).
        public var position: TimeInterval?
        public var duration: TimeInterval?
        public var rate: Double
        public var positionDate: Date
        public var canPrevious: Bool
        public var canNext: Bool
        /// The controls' titles: play, pause, previous, next.
        public var labels: [String: String]
        /// The name of the app that plays (Spotify, Music) for the menu's Open in; nil for cmux's own.
        public var source: String?

        public init(title: String, artist: String, artwork: String?, isPlaying: Bool, position: TimeInterval?, duration: TimeInterval?,
                    rate: Double, positionDate: Date, canPrevious: Bool, canNext: Bool, labels: [String: String], source: String? = nil) {
            self.title = title
            self.artist = artist
            self.artwork = artwork
            self.isPlaying = isPlaying
            self.position = position
            self.duration = duration
            self.rate = rate
            self.positionDate = positionDate
            self.canPrevious = canPrevious
            self.canNext = canNext
            self.labels = labels
            self.source = source
        }

        var json: JSONValue {
            var object: [String: JSONValue] = [
                "title": .string(title), "artist": .string(artist), "playing": .bool(isPlaying), "rate": .number(rate),
                "positionDate": .number((positionDate.timeIntervalSince1970 * 1000).rounded()),
                "canPrevious": .bool(canPrevious), "canNext": .bool(canNext),
                "labels": .object(labels.mapValues { .string($0) }),
            ]
            if let artwork { object["artwork"] = .string(artwork) }
            if let position { object["position"] = .number(position) }
            if let duration { object["duration"] = .number(duration) }
            if let source { object["source"] = .string(source) }
            return .object(object)
        }
    }

    /// A page's control (`nowPlaying.command {command, seconds}`), or its menu's page items.
    public nonisolated enum Command: Hashable, Sendable {
        case playPause
        case previous
        case next
        case seek(TimeInterval)
        /// Open in: brings the app that plays forward.
        case open
        /// Hide Now Playing (false) and its Undo (true): `tabs.newTabNowPlaying`.
        case show(Bool)
        /// Now Playing Settings…: Settings at `tabs.newTabNowPlaying`.
        case settings

        /// The page's params, nil for anything else.
        init?(_ params: [String: Any]?) {
            switch params?["command"] as? String {
            case "playPause": self = .playPause
            case "previous": self = .previous
            case "next": self = .next
            case "open": self = .open
            case "hide": self = .show(false)
            case "show": self = .show(true)
            case "settings": self = .settings
            case "seek":
                guard let seconds = (params?["seconds"] as? NSNumber)?.doubleValue, seconds.isFinite, seconds >= 0 else { return nil }
                self = .seek(seconds)
            default: return nil
            }
        }
    }

    /// The track, read now, as a page host event; `view` then also gets every change.
    func event(for view: AgentPaneView) -> AgentPageEvent {
        views.add(view)
        return .nowPlaying(track)
    }

    /// Pushes the track, read now, to `view`'s page; `view` then also gets every change.
    func push(to view: AgentPaneView) {
        views.add(view)
        send(to: view)
    }

    private func send(to view: AgentPaneView) {
        let event = AgentPageEvent.nowPlaying(track)
        view.deliver([event])
    }

    /// Runs a page's control; false when the App has not wired the player.
    func perform(_ command: Command) -> Bool {
        guard let onCommand else { return false }
        onCommand(command)
        return true
    }
}

extension AgentPageEvent {
    /// What plays, for the New Tab page's player (`nowPlaying`); null while nothing does.
    static func nowPlaying(_ track: AgentPaneNowPlaying.Track?) -> AgentPageEvent {
        AgentPageEvent(kind: "nowPlaying", value: track?.json ?? .null)
    }
}

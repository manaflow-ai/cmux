public import Foundation

/// `media.get` and `media.control` (scopes `media:read` and `media:control`): what plays in cmux, the
/// track the Now Playing card shows, and its transport, for an extension's own player. The App
/// reads the card's sources (cmux's player, a browser tab playing aloud, another app while
/// `sidebar.nowPlaying.otherApps` is on); this owner only shapes the answer and checks the params.
/// The supervisor lets `media.control` through only on a tap (`PLAYBACK_OPS` in
/// cmux-app-manifest), and this owner refuses a script origin too, so no extension starts, pauses
/// or skips sound on its own. `media.changed` (``AppProviderChangeFeed``) tells readers to read again.
public nonisolated struct MediaAppOps: AppHostCapabilityHandler {
    /// One track as `media.get` answers it.
    public struct Track: Hashable, Sendable {
        public var title: String
        public var artist: String
        /// A `data:image/png;base64,` URL, small (the App redraws the artwork); nil without artwork.
        public var artwork: String?
        public var isPlaying: Bool
        /// Seconds in at `positionDate`; nil for a live stream.
        public var position: TimeInterval?
        /// The length in seconds; nil when unknown or endless.
        public var duration: TimeInterval?
        public var rate: Double
        public var positionDate: Date
        public var canPrevious: Bool
        public var canNext: Bool
        /// The name of the other app that plays; nil for cmux's own player and tabs.
        public var source: String?

        public init(title: String, artist: String, artwork: String?, isPlaying: Bool, position: TimeInterval?,
                    duration: TimeInterval?, rate: Double, positionDate: Date, canPrevious: Bool, canNext: Bool,
                    source: String?) {
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
            self.source = source
        }

        /// The track in the `media.now_playing` signal's shape (schema/v2/signals.json).
        public var appJSON: AppJSON {
            var object: [String: AppJSON] = [
                "title": .string(title), "artist": .string(artist), "playing": .bool(isPlaying), "rate": .number(rate),
                "position_ms": .number((positionDate.timeIntervalSince1970 * 1000).rounded()),
                "can_previous": .bool(canPrevious), "can_next": .bool(canNext),
            ]
            if let artwork, artwork.utf8.count <= MediaAppOps.maxArtworkBytes { object["artwork"] = .string(artwork) }
            if let position, position.isFinite { object["position"] = .number(position) }
            if let duration, duration.isFinite { object["duration"] = .number(duration) }
            if let source { object["source"] = .string(source) }
            return .object(object)
        }
    }

    /// A transport control `media.control` runs.
    public enum Command: Hashable, Sendable {
        case playPause
        case previous
        case next
        /// Moves to this many seconds in.
        case seek(TimeInterval)
    }

    /// Largest artwork data URL passed on; a bigger one is left out rather than sent to every reader.
    public static let maxArtworkBytes = 256 * 1024

    private let track: @MainActor @Sendable () -> Track?
    private let perform: @MainActor @Sendable (Command) -> Bool

    /// - Parameters:
    ///   - track: What plays now, nil while nothing does; read at each call.
    ///   - perform: Runs a control on what plays; false when nothing plays to take it.
    public init(track: @escaping @MainActor @Sendable () -> Track?, perform: @escaping @MainActor @Sendable (Command) -> Bool) {
        self.track = track
        self.perform = perform
    }

    /// The capability family supplied on the verified-app provider channel.
    public var families: Set<String> { ["media"] }

    /// `media.get` answers `{track: {...} | null}`; `media.control {command, seconds?}` answers null.
    /// - Parameter request: The supervisor-admitted call.
    /// - Returns: The answer in the signal's shape.
    /// - Throws: `operation.unsupported` for another op, `validation.invalid` for bad params,
    ///   `gesture.required` for a control from a script, `media.nothing_playing` when nothing takes it.
    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        switch request.op {
        case "media.get":
            guard request.params == .null || request.params.objectValue?.isEmpty == true else {
                throw AppHostCapabilityError(code: "validation.invalid", message: "media.get takes no params")
            }
            return ["track": await track()?.appJSON ?? .null]
        case "media.control":
            let command = try Self.command(request.params)
            guard request.origin == "user" else {
                throw AppHostCapabilityError(code: "gesture.required", message: "media.control runs only from a tap")
            }
            guard await perform(command) else {
                throw AppHostCapabilityError(code: "media.nothing_playing", message: "nothing plays in cmux to take the control")
            }
            return .null
        default:
            throw .unsupported(request.op)
        }
    }

    /// The control `params` asks for: `{command: play_pause | previous | next | seek, seconds}`.
    static func command(_ params: AppJSON) throws(AppHostCapabilityError) -> Command {
        switch params["command"]?.stringValue {
        case "play_pause": return .playPause
        case "previous": return .previous
        case "next": return .next
        case "seek":
            guard let seconds = params["seconds"]?.numberValue, seconds.isFinite, seconds >= 0 else {
                throw AppHostCapabilityError(code: "validation.invalid", message: "seek needs seconds, a number of at least 0")
            }
            return .seek(seconds)
        default:
            throw AppHostCapabilityError(code: "validation.invalid", message: "command is play_pause, previous, next or seek")
        }
    }
}

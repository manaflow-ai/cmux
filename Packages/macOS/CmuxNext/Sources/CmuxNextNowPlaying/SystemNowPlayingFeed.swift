import CmuxNextCompat
public import Foundation

/// What macOS Now Playing reports for the app that plays (Spotify, Music, a
/// browser), as the MediaRemote adapter streams it (`stream --micros`,
/// ungive/mediaremote-adapter): one JSON object a line,
/// `{"type": "data", "diff": Bool, "payload": {...}}`. A full payload replaces
/// what was known; a diff updates it, and a null value removes that key. No
/// keys at all means nothing plays.
public nonisolated struct SystemNowPlayingFeed: Equatable, Sendable {
    /// One payload value; the adapter reports strings, numbers and booleans.
    public nonisolated enum Field: Decodable, Equatable, Sendable {
        case bool(Bool)
        case number(Double)
        case string(String)

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else {
                self = .string(try container.decode(String.self))
            }
        }

        var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
        var number: Double? { if case .number(let value) = self { value } else { nil } }
        var string: String? { if case .string(let value) = self { value } else { nil } }
    }

    private nonisolated struct Line: Decodable {
        var type: String
        var diff: Bool?
        var payload: [String: Field?]?
    }

    /// One data line of the stream, decoded. Decoding is the costly part (an artwork line carries
    /// megabytes of base64), so the adapter decodes on its pipe's queue and hands the main actor this.
    public nonisolated struct Update: Equatable, Sendable {
        /// Only the keys that changed; false replaces everything known.
        public var diff: Bool
        /// A nil value removes that key.
        public var payload: [String: Field?]

        /// The update a stream line carries; nil for a line that is not a data line.
        public static func decode(_ line: Data) -> Update? {
            guard let decoded = try? JSONDecoder().blockingDecode(Line.self, from: line), decoded.type == "data",
                  let payload = decoded.payload else { return nil }
            return Update(diff: decoded.diff == true, payload: payload)
        }
    }

    /// The payload as known so far.
    public private(set) var fields: [String: Field] = [:]

    public init() {}

    public mutating func apply(_ update: Update) {
        if !update.diff { fields = [:] }
        for (key, value) in update.payload { fields[key] = value }
    }

    /// Takes one line of the stream; false (and nothing changes) for a line that is not a data line.
    @discardableResult
    public mutating func apply(_ line: Data) -> Bool {
        guard let update = Update.decode(line) else { return false }
        apply(update)
        return true
    }

    /// What plays, once the adapter has said which app, what title and whether it plays.
    public var report: SystemNowPlayingReport? {
        guard let bundle = fields["bundleIdentifier"]?.string, let title = fields["title"]?.string, !title.isEmpty,
              let playing = fields["playing"]?.bool else { return nil }
        let micros = { (key: String) in self.fields[key]?.number.map { $0 / 1_000_000 } }
        return SystemNowPlayingReport(
            bundleIdentifier: bundle, parentBundleIdentifier: fields["parentApplicationBundleIdentifier"]?.string,
            title: title, artist: fields["artist"]?.string ?? "", album: fields["album"]?.string ?? "", isPlaying: playing,
            duration: micros("durationMicros").flatMap { $0 > 0 ? $0 : nil }, elapsed: micros("elapsedTimeMicros"),
            timestamp: micros("timestampEpochMicros").map(Date.init(timeIntervalSince1970:)),
            rate: fields["playbackRate"]?.number ?? (playing ? 1 : 0), artwork: fields["artworkData"]?.string)
    }
}

/// One app's report through macOS Now Playing (``SystemNowPlayingFeed``).
public nonisolated struct SystemNowPlayingReport: Equatable, Sendable {
    public var bundleIdentifier: String
    /// The app a helper process plays for (a browser's media process names its browser).
    public var parentBundleIdentifier: String?
    public var title: String
    public var artist: String
    public var album: String
    public var isPlaying: Bool
    /// The length in seconds; nil when unknown or endless.
    public var duration: TimeInterval?
    /// The position in seconds at `timestamp`.
    public var elapsed: TimeInterval?
    public var timestamp: Date?
    public var rate: Double
    /// The artwork image, base64-encoded as the adapter sends it.
    public var artwork: String?

    /// Whether `bundles` holds the app that plays or the app it plays for.
    public func isFrom(_ bundles: Set<String>) -> Bool {
        bundles.contains(bundleIdentifier) || parentBundleIdentifier.map(bundles.contains) == true
    }
}

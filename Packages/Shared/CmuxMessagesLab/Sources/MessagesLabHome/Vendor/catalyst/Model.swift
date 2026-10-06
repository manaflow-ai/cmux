import Foundation

// Mirrors shared/MODEL.md field for field. Enums are tagged unions keyed by `type`.

typealias ID = String

struct Conversation: Codable, Equatable {
    var id: ID
    var title: String
    var participants: [Participant]
    var messages: [Message]
}

struct Participant: Codable, Equatable {
    var id: ID
    var displayName: String
    var isMe: Bool
    var avatar: Avatar?

    enum Avatar: Codable, Equatable {
        case monogram(String)
        case image(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            if let m = try c.decodeIfPresent(String.self, forKey: .monogram) { self = .monogram(m) }
            else { self = .image(try c.decode(String.self, forKey: .image)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            switch self {
            case let .monogram(m): try c.encode(m, forKey: .monogram)
            case let .image(i): try c.encode(i, forKey: .image)
            }
        }
        enum K: String, CodingKey { case monogram, image }
    }
}

struct PartRef: Codable, Hashable {
    var messageId: ID
    var partIndex: Int
}

struct Message: Codable, Equatable {
    var id: ID
    var senderId: ID
    var sentAt: String
    var parts: [Part]
    var replyTo: PartRef?
    var status: DeliveryStatus?
    var edits: [Edit]?
    var retractedAt: String?
    var reactions: [Reaction]
    /// Deleted on this device (Delete… in the menu): no row is drawn. A tombstone, so
    /// paged indices stay valid.
    var deletedAt: String? = nil

    struct Edit: Codable, Equatable { var text: String; var at: String }

    var date: Date { Instant.parse(sentAt) }
}

enum DeliveryStatus: Codable, Equatable {
    case sending, sent
    case delivered(at: String)
    case read(at: String)
    case failed(reason: String?)

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .state) {
        case "sending": self = .sending
        case "sent": self = .sent
        case "delivered": self = .delivered(at: try c.decode(String.self, forKey: .at))
        case "read": self = .read(at: try c.decode(String.self, forKey: .at))
        default: self = .failed(reason: try c.decodeIfPresent(String.self, forKey: .reason))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .sending: try c.encode("sending", forKey: .state)
        case .sent: try c.encode("sent", forKey: .state)
        case let .delivered(at): try c.encode("delivered", forKey: .state); try c.encode(at, forKey: .at)
        case let .read(at): try c.encode("read", forKey: .state); try c.encode(at, forKey: .at)
        case let .failed(r): try c.encode("failed", forKey: .state); try c.encodeIfPresent(r, forKey: .reason)
        }
    }
    enum K: String, CodingKey { case state, at, reason }
}

enum Part: Codable, Hashable {
    case text(String, runs: [TextRun])
    case link(url: String, title: String?, siteName: String?, image: String?, theme: String?)
    case attachment(Attachment)
    case location(latitude: Double, longitude: Double, title: String?, subtitle: String?)

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text), runs: try c.decodeIfPresent([TextRun].self, forKey: .runs) ?? [])
        case "link":
            self = .link(url: try c.decode(String.self, forKey: .url), title: try c.decodeIfPresent(String.self, forKey: .title),
                         siteName: try c.decodeIfPresent(String.self, forKey: .siteName),
                         image: try c.decodeIfPresent(String.self, forKey: .image), theme: try c.decodeIfPresent(String.self, forKey: .theme))
        case "attachment":
            self = .attachment(try c.decode(Attachment.self, forKey: .attachment))
        default:
            self = .location(latitude: try c.decode(Double.self, forKey: .latitude), longitude: try c.decode(Double.self, forKey: .longitude),
                             title: try c.decodeIfPresent(String.self, forKey: .title), subtitle: try c.decodeIfPresent(String.self, forKey: .subtitle))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case let .text(t, runs):
            try c.encode("text", forKey: .type); try c.encode(t, forKey: .text); if !runs.isEmpty { try c.encode(runs, forKey: .runs) }
        case let .link(url, title, site, image, theme):
            try c.encode("link", forKey: .type); try c.encode(url, forKey: .url); try c.encodeIfPresent(title, forKey: .title)
            try c.encodeIfPresent(site, forKey: .siteName); try c.encodeIfPresent(image, forKey: .image); try c.encodeIfPresent(theme, forKey: .theme)
        case let .attachment(a):
            try c.encode("attachment", forKey: .type); try c.encode(a, forKey: .attachment)
        case let .location(lat, lon, title, sub):
            try c.encode("location", forKey: .type); try c.encode(lat, forKey: .latitude); try c.encode(lon, forKey: .longitude)
            try c.encodeIfPresent(title, forKey: .title); try c.encodeIfPresent(sub, forKey: .subtitle)
        }
    }
    enum K: String, CodingKey { case type, text, runs, url, title, siteName, image, theme, attachment, latitude, longitude, subtitle }

    var plainText: String? { if case let .text(t, _) = self { return t } else { return nil } }
}

struct TextRun: Codable, Hashable {
    var start: Int
    var length: Int
    var style: [String]?
    var link: String?
    var mention: ID?
    var detected: String?
}

struct Attachment: Codable, Hashable {
    var id: ID
    var kind: String            // image | video | audio | voiceMemo | file | contact
    var fileName: String
    var mimeType: String
    var byteSize: Int
    var asset: String?
    var poster: String?
    var width: Int?
    var height: Int?
    var durationSeconds: Double?
    var transfer: Transfer

    enum Transfer: Codable, Hashable {
        case done
        case uploading(Double)
        case downloading(Double)
        case failed
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            switch try c.decode(String.self, forKey: .state) {
            case "done": self = .done
            case "uploading": self = .uploading(try c.decode(Double.self, forKey: .progress))
            case "downloading": self = .downloading(try c.decode(Double.self, forKey: .progress))
            default: self = .failed
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            switch self {
            case .done: try c.encode("done", forKey: .state)
            case let .uploading(p): try c.encode("uploading", forKey: .state); try c.encode(p, forKey: .progress)
            case let .downloading(p): try c.encode("downloading", forKey: .state); try c.encode(p, forKey: .progress)
            case .failed: try c.encode("failed", forKey: .state)
            }
        }
        enum K: String, CodingKey { case state, progress }
    }
}

struct Reaction: Codable, Hashable {
    var senderId: ID
    var partIndex: Int
    var kind: Kind
    var at: String

    enum Kind: Codable, Hashable {
        case tapback(String)    // love | like | dislike | laugh | emphasize | question
        case emoji(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            if let t = try c.decodeIfPresent(String.self, forKey: .tapback) { self = .tapback(t) }
            else { self = .emoji(try c.decode(String.self, forKey: .emoji)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            switch self {
            case let .tapback(t): try c.encode(t, forKey: .tapback)
            case let .emoji(e): try c.encode(e, forKey: .emoji)
            }
        }
        enum K: String, CodingKey { case tapback, emoji }
    }
}

enum Instant {
    private static let parser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    /// Timestamps keep the conversation's offset (-07:00) so rendering is
    /// independent of the machine's zone.
    /// cmux: a live Home transcript shows the user's zone and locale; it
    /// sets `liveZone` / `liveLocale` before the first date is formatted.
    /// Unset (fixtures, the differential harness), the conversation's -07:00.
    static var liveZone: TimeZone?
    static var liveLocale: Locale?
    static let zone = liveZone ?? TimeZone(secondsFromGMT: -7 * 3600)!
    static let locale = liveLocale ?? Locale(identifier: "en_US")
    private static let writer: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = zone
        return f
    }()
    private static var memo: [String: Date] = [:]
    private static let lock = NSLock()
    /// Memoized: rows re-derive often and 50k timestamps parse slowly.
    static func parse(_ s: String) -> Date {
        lock.lock()
        if let d = memo[s] { lock.unlock(); return d }
        lock.unlock()
        let d = parser.date(from: s) ?? Date(timeIntervalSince1970: 0)
        lock.lock(); memo[s] = d; lock.unlock()
        return d
    }
    static func format(_ d: Date) -> String { writer.string(from: d) }

    /// Calendar of the conversation's zone (day boundaries for separators).
    static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }()

    /// `s` moved by `seconds` (no memo: shifted pages are decoded once).
    static func shift(_ s: String, by seconds: TimeInterval) -> String {
        guard let d = parser.date(from: s) else { return s }
        return writer.string(from: d.addingTimeInterval(seconds))
    }
}

extension Message {
    /// Every instant of the message moved by `seconds` (fixture date shift).
    func shifted(by seconds: TimeInterval) -> Message {
        guard seconds != 0 else { return self }
        var m = self
        m.sentAt = Instant.shift(sentAt, by: seconds)
        m.retractedAt = retractedAt.map { Instant.shift($0, by: seconds) }
        m.edits = edits?.map { Edit(text: $0.text, at: Instant.shift($0.at, by: seconds)) }
        m.reactions = reactions.map { var r = $0; r.at = Instant.shift(r.at, by: seconds); return r }
        switch status {
        case let .delivered(at): m.status = .delivered(at: Instant.shift(at, by: seconds))
        case let .read(at): m.status = .read(at: Instant.shift(at, by: seconds))
        default: break
        }
        return m
    }
}

enum Fixtures {
    /// conversation.json and assets/ from shared/ are bundled (not copied
    /// into this variant's sources).
    /// cmux: fixtures are not in the app bundle; the harness sets `root`.
    static var root: URL?
    static var sharedDirectory: URL { root ?? Bundle.main.resourceURL! }
    /// The repo's shared/ directory, for the large generated stores that are
    /// not bundled.
    static var repoShared: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("shared")
    }
    static func loadConversation() -> Conversation {
        let url = sharedDirectory.appendingPathComponent("conversation.json")
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(Conversation.self, from: data)
    }
    /// Resolve an AssetRef: a path relative to shared/assets or a file URL.
    static func assetURL(_ ref: String) -> URL {
        if ref.hasPrefix("file:") { return URL(string: ref)! }
        // Catalyst fixture assets (Fixtures/real, bundled as `real/`).
        if ref.hasPrefix("real/") { return sharedDirectory.appendingPathComponent(ref) }
        return sharedDirectory.appendingPathComponent("assets").appendingPathComponent(ref)
    }
}

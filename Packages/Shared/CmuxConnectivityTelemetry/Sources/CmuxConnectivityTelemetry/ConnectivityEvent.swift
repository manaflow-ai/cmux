import Foundation

/// One connectivity step, as the code that saw it reports it. The policy decides what of it is
/// kept for the device's ``ConnectivityAudience``.
public struct ConnectivityEvent: Sendable, Equatable {
    /// The connection the step belongs to.
    public enum Area: String, Sendable, Equatable, Codable, CaseIterable {
        /// The phone's link to a Mac (dial, path, liveness, roaming, media).
        case link
        /// The phone's agent hub (acpmux) over a link.
        case hub
        /// Phone pairing and approval, on either side.
        case pairing
        /// The Mac's phone host process (`cmux-mobile-host`) and the iPhone host service.
        case phoneHost
        /// The Mac's `cmux link` for the Cloud app server.
        case cloudLink
        /// The device's network path.
        case network
    }

    /// How the step ended.
    public enum Outcome: String, Sendable, Equatable, Codable {
        case info
        case success
        case failure
    }

    /// A field value. ``code``, ``number`` and ``flag`` are recorded for everyone: a code must be
    /// a fixed word the code chose (a path kind, a phase), never text from outside. ``text`` is
    /// free text (an error message, an endpoint, an id) and is recorded for the team only.
    public enum Value: Sendable, Equatable, Codable {
        case code(String)
        case number(Double)
        case flag(Bool)
        case text(String)

        /// A code from another component (a Rust error code, an HTTP phase): kept as a code
        /// when it is one short snake_case word, else `other`, so a message that arrives
        /// where a code was expected never reaches everyone's records.
        public static func safeCode(_ raw: String) -> Value {
            let isWord = (1...40).contains(raw.count) && raw.unicodeScalars.allSatisfy { scalar in
                (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "_" || scalar == "-"
            }
            return .code(isWord ? raw : "other")
        }

        /// Whether everyone's records may carry it.
        public var isFixedVocabulary: Bool {
            if case .text = self { return false }
            return true
        }

        /// A journal line keeps the kind: a number or flag is bare, a code is `{"code": "…"}` and a
        /// text `{"text": "…"}`, so a record read back can still be filtered by kind.
        private enum Tagged: String, CodingKey {
            case code
            case text
        }

        public init(from decoder: any Decoder) throws {
            if let tagged = try? decoder.container(keyedBy: Tagged.self) {
                if let code = try tagged.decodeIfPresent(String.self, forKey: .code) {
                    self = .code(code)
                    return
                }
                self = .text(try tagged.decode(String.self, forKey: .text))
                return
            }
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                self = .flag(flag)
            } else {
                self = .number(try container.decode(Double.self))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case .code(let value):
                var container = encoder.container(keyedBy: Tagged.self)
                try container.encode(value, forKey: .code)
            case .text(let value):
                var container = encoder.container(keyedBy: Tagged.self)
                try container.encode(value, forKey: .text)
            case .number(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .flag(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            }
        }

        /// Whether `key` may name a field in everyone's records: one short ASCII snake_case word.
        public static func isSafeKey(_ key: String) -> Bool {
            (1...40).contains(key.utf8.count) && key.utf8.allSatisfy { byte in
                (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x5F
            }
        }
    }

    public var area: Area
    /// The step, a fixed snake_case word (`dial_failed`).
    public var name: String
    public var outcome: Outcome
    public var fields: [String: Value]
    /// Free text about the step (the error as thrown, the endpoint). Team only.
    public var detail: String?
    public var date: Date

    public init(_ area: Area, _ name: String, outcome: Outcome = .info, fields: [String: Value] = [:],
                detail: String? = nil, date: Date = Date()) {
        self.area = area
        self.name = name
        self.outcome = outcome
        self.fields = fields
        self.detail = detail
        self.date = date
    }

    /// The key grouping uses: `area.name`.
    public var key: String { "\(area.rawValue).\(name)" }

    /// The key everyone's sampling counts by: `area.name`, plus the event's `phase` or `state`
    /// code when it has one, so `connecting` and `connected` are sampled apart.
    public var samplingKey: String {
        for field in ["phase", "state"] {
            if case .code(let value)? = fields[field] { return "\(key).\(value)" }
        }
        return key
    }
}

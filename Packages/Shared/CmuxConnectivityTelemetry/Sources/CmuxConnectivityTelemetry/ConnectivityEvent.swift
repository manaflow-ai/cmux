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

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                self = .flag(flag)
            } else if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else {
                self = .text(try container.decode(String.self))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .code(let value), .text(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .flag(let value): try container.encode(value)
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

    /// The key sampling and grouping use: `area.name`.
    public var key: String { "\(area.rawValue).\(name)" }
}

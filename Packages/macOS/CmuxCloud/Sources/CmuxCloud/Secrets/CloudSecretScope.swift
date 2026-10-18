import Foundation

/// Where a Cloud Secret applies.
///
/// A name can be stored in several scopes at once; the most specific scope wins when a
/// machine's effective set is computed (``machine(_:)`` over ``project(_:)`` over ``all``).
/// The scope encodes as its ``wireValue`` so the vault document and socket payloads
/// share one spelling.
public enum CloudSecretScope: Hashable, Codable, Sendable {
    /// Every Cloud machine opened from this Mac.
    case all
    /// Machines linked to one project; the payload is a normalized project key
    /// (see ``CloudSecretProjectKey``).
    case project(String)
    /// One machine, by machine ID.
    case machine(String)

    /// Precedence on a name clash: `all` = 0, `project` = 1, `machine` = 2.
    public var rank: Int {
        switch self {
        case .all: return 0
        case .project: return 1
        case .machine: return 2
        }
    }

    /// `all`, `project:<key>` or `machine:<id>`.
    public var wireValue: String {
        switch self {
        case .all: return "all"
        case .project(let key): return "project:\(key)"
        case .machine(let id): return "machine:\(id)"
        }
    }

    /// The project key or machine ID, empty for ``all``.
    public var target: String {
        switch self {
        case .all: return ""
        case .project(let key): return key
        case .machine(let id): return id
        }
    }

    /// Parses a ``wireValue``. Returns `nil` for an unknown kind or an empty target.
    public init?(wireValue: String) {
        if wireValue == "all" {
            self = .all
            return
        }
        guard let colon = wireValue.firstIndex(of: ":") else { return nil }
        let kind = wireValue[..<colon]
        let target = String(wireValue[wireValue.index(after: colon)...])
        guard !target.isEmpty else { return nil }
        switch kind {
        case "project": self = .project(target)
        case "machine": self = .machine(target)
        default: return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let scope = CloudSecretScope(wireValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown secret scope '\(raw)'")
        }
        self = scope
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

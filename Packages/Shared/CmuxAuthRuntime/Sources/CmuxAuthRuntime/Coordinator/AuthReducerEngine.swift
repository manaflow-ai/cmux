public import CMUXAuthCore
public import Foundation

/// The Rust auth reducer (cmux-tui/crates/cmux-auth-coordinator) behind one
/// of its two bindings: the C ABI in the Mac app's CCmuxAppFFI and the
/// UniFFI object in the iPhone app's CmuxMobileLinkFFI. It takes and returns
/// the crate's JSON wire; ``AuthCoordinator`` runs the effects it queues.
public protocol AuthReducerEngine: AnyObject {
    /// Applies one event. Throws when the event is not the reducer's JSON.
    func feed(_ event: Data) throws
    /// The queued effects as a JSON array, oldest first; the queue empties.
    func takeEffects() -> Data
    /// What the reducer publishes now, as a JSON object.
    func snapshot() -> Data
}

/// Makes the reducer from its config JSON (`{launch, persisted, jitterSeed}`).
public typealias AuthReducerFactory = (_ config: Data) throws -> any AuthReducerEngine

/// One JSON value of the reducer's wire, as Swift passes it through: events
/// are built from it, effects are read from it, and tickets ride back as is.
enum AuthWire: Sendable, Equatable, Codable, ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral {
    case null, bool(Bool), int(Int64), double(Double), string(String), array([AuthWire]), object([String: AuthWire])

    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(dictionaryLiteral elements: (String, AuthWire)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    init(arrayLiteral elements: AuthWire...) { self = .array(elements) }
    init(nilLiteral: ()) { self = .null }
    init(_ value: UInt64) { self = .int(Int64(truncatingIfNeeded: value)) }
    init(_ value: String?) { self = value.map(AuthWire.string) ?? .null }
    init(milliseconds duration: Duration?) {
        self = duration.map { .int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000) } ?? .null
    }
    /// The serde form of `Result`: `{"Ok": value}` or `{"Err": failure}`.
    static func ok(_ value: AuthWire = .null) -> AuthWire { ["Ok": value] }
    static func err(_ failure: AuthWire) -> AuthWire { ["Err": failure] }
    /// Any `Codable` value, through its JSON (users, teams).
    init<T: Encodable>(encoding value: T) {
        self = (try? JSONDecoder().decode(AuthWire.self, from: JSONEncoder().encode(value))) ?? .null
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([AuthWire].self) { self = .array(v) }
        else { self = .object(try c.decode([String: AuthWire].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(v): try c.encode(v)
        case let .int(v): try c.encode(v)
        case let .double(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        }
    }

    subscript(key: String) -> AuthWire { if case let .object(o) = self { o[key] ?? .null } else { .null } }
    var string: String? { if case let .string(v) = self { v } else { nil } }
    var bool: Bool { if case let .bool(v) = self { v } else { false } }
    var uint: UInt64 { if case let .int(v) = self { UInt64(truncatingIfNeeded: v) } else { 0 } }
    var array: [AuthWire] { if case let .array(v) = self { v } else { [] } }
    var duration: Duration { if case let .int(v) = self { .milliseconds(v) } else { .zero } }
    /// An externally tagged enum value: a unit variant is its name, any
    /// other variant a one-key object.
    var variant: (tag: String, payload: AuthWire) {
        switch self {
        case let .string(tag): (tag, .null)
        case let .object(o) where o.count == 1: (o.keys.first ?? "", o.values.first ?? .null)
        default: ("", .null)
        }
    }
    func decoded<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// The reducer's user: Swift's ``CMUXAuthUser`` with the wire's key for the image.
struct AuthWireUser: Codable, Equatable, Sendable {
    var id: String
    var primaryEmail: String?
    var displayName: String?
    var profileImageUrl: String?
    var demonstrationContentEnabled: Bool

    init(_ user: CMUXAuthUser) {
        self.init(id: user.id, primaryEmail: user.primaryEmail, displayName: user.displayName,
                  profileImageUrl: user.profileImageURL, demonstrationContentEnabled: user.demonstrationContentEnabled)
    }
    init(id: String, primaryEmail: String?, displayName: String?, profileImageUrl: String?, demonstrationContentEnabled: Bool) {
        (self.id, self.primaryEmail, self.displayName) = (id, primaryEmail, displayName)
        (self.profileImageUrl, self.demonstrationContentEnabled) = (profileImageUrl, demonstrationContentEnabled)
    }
    var user: CMUXAuthUser {
        CMUXAuthUser(id: id, primaryEmail: primaryEmail, displayName: displayName,
                     profileImageURL: profileImageUrl, demonstrationContentEnabled: demonstrationContentEnabled)
    }
}

/// What the reducer publishes, decoded from ``AuthReducerEngine/snapshot()``.
struct AuthReducerSnapshot: Decodable, Equatable {
    struct Identity: Decodable, Equatable { var generation: UInt64; var accountId: String }
    struct Scope: Decodable, Equatable { var session: Identity; var teamId: String; var generation: UInt64 }
    struct CachedTeam: Decodable, Equatable { var accountId: String; var teamId: String }

    var isAuthenticated: Bool
    var currentUser: AuthWireUser?
    var isRestoringSession: Bool
    var isLoading: Bool
    var availableTeams: [CMUXAuthTeam]
    var selectedTeamId: String?
    var resolvedTeamId: String?
    var sessionGeneration: UInt64
    var signOutRevision: UInt64
    var lastSignOutReason: String?
    var hasPendingCode: Bool
    var teamScopeGeneration: UInt64
    var hasPendingTeamScopeRecovery: Bool
    var needsTeamScopeRecovery: Bool
    var sessionTokenTransitionIsActive: Bool
    var sessionIdentity: Identity?
    var publishedSessionIdentity: Identity?
    var teamScope: Scope?
    var cachedTeamIdentity: CachedTeam?
    var tokenStoreWriteHighWater: UInt64
    var hasActiveSignInFlows: Bool
}

extension AuthReducerSnapshot.Identity {
    var identity: AuthenticatedSessionIdentity { AuthenticatedSessionIdentity(generation: generation, accountID: accountId) }
}

extension AuthReducerSnapshot.Scope {
    var scope: AuthenticatedTeamScope {
        AuthenticatedTeamScope(session: session.identity, teamID: teamId, generation: generation)
    }
}

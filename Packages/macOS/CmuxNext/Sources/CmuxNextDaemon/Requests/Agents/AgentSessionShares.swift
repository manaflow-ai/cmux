import Foundation

// Link shares of an agent chat (`agent-session-share-*`, cmux-tui-core
// server/agent_session_shares.rs; design chat-multiplayer.md 4.2): the owner shares one chat with
// a guest through a link that works a few times (once by default) and expires (24 h by default).
// The daemon answers these only on the owner's own local unix connection; a remote machine's
// daemon refuses them (`share.not_trusted`).

/// `agent-session-share-create`: a new link for the chat on `surface`. `ownerToken` is the owner's
/// cmux install token, which the daemon spends once on the hosted room's provisioning and never
/// stores; without one a daemon bridged to a room answers `share.needs_sign_in`.
public struct AgentSessionShareCreateRequest: DaemonRequest {
    public typealias Response = AgentSessionShareCreated
    public static let command = "agent-session-share-create"

    public var surface: UInt64
    /// The acpmux session the caller saw on `surface`; the daemon refuses (`share.chat_moved`) when
    /// the surface shows another one by the time the request arrives.
    public var session: String?
    /// The caller's id for this request: list shows it, so a caller whose create went unanswered
    /// can find and end that one share.
    public var createId: String?
    public var ttlSecs: UInt64?
    public var uses: UInt32?
    public var ownerToken: String?

    public init(surface: UInt64, session: String? = nil, createId: String? = nil, ttlSecs: UInt64? = nil, uses: UInt32? = nil,
                ownerToken: String? = nil) {
        self.surface = surface
        self.session = session
        self.createId = createId
        self.ttlSecs = ttlSecs
        self.uses = uses
        self.ownerToken = ownerToken
    }
}

/// `agent-session-share-list`: every share, or the shares of the chat on `surface`.
public struct AgentSessionShareListRequest: DaemonRequest {
    public typealias Response = AgentSessionShareList
    public static let command = "agent-session-share-list"

    public var surface: UInt64?

    public init(surface: UInt64? = nil) { self.surface = surface }
}

/// `agent-session-share-revoke`: the link stops working and its guests leave.
public struct AgentSessionShareRevokeRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "agent-session-share-revoke"

    public var shareId: String

    public init(shareId: String) { self.shareId = shareId }
}

/// `agent-session-share-kick`: one guest leaves the link and cannot join again.
public struct AgentSessionShareKickRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "agent-session-share-kick"

    public var shareId: String
    public var guestId: String

    public init(shareId: String, guestId: String) {
        self.shareId = shareId
        self.guestId = guestId
    }
}

/// What create answers. `url` is the guest link (`<room>/g/<share_id>#<secret>`), nil when the
/// daemon has no hosted room; the secret travels only inside it and is not kept here.
public struct AgentSessionShareCreated: Decodable, Sendable, Equatable {
    public var shareId: String
    public var url: String?
    /// Milliseconds since 1970.
    public var expiresAt: UInt64
    public var session: String
    public var surface: UInt64
    public var usesLeft: UInt32

    enum CodingKeys: String, CodingKey {
        case url, session, surface
        case shareId = "share_id"
        case expiresAt = "expires_at"
        case usesLeft = "uses_left"
    }

    public init(shareId: String, url: String?, expiresAt: UInt64, session: String, surface: UInt64, usesLeft: UInt32) {
        self.shareId = shareId
        self.url = url
        self.expiresAt = expiresAt
        self.session = session
        self.surface = surface
        self.usesLeft = usesLeft
    }
}

public struct AgentSessionShareList: Decodable, Sendable, Equatable {
    public var shares: [AgentSessionShare]

    public init(shares: [AgentSessionShare]) { self.shares = shares }
}

/// One share as list shows it (never its secret or the room's tokens).
public struct AgentSessionShare: Decodable, Sendable, Equatable, Identifiable {
    /// `provisioning`, `active`, `revoked`, `expired` or `closed`.
    public var state: String
    public var shareId: String
    public var session: String
    public var surface: UInt64
    public var createdAt: UInt64
    /// The creating request's `createId`, when its caller gave one.
    public var createId: String?
    public var expiresAt: UInt64
    public var expiresInSecs: UInt64
    public var usesLeft: UInt32
    /// The hosted room's origin, nil without one.
    public var room: String?
    public var guests: [AgentSessionShareGuest]

    public var id: String { shareId }
    public var isLive: Bool { state == "active" || state == "provisioning" }

    enum CodingKeys: String, CodingKey {
        case state, session, surface, room, guests
        case shareId = "share_id"
        case createdAt = "created_at"
        case createId = "create_id"
        case expiresAt = "expires_at"
        case expiresInSecs = "expires_in_secs"
        case usesLeft = "uses_left"
    }
}

public struct AgentSessionShareGuest: Decodable, Sendable, Equatable, Identifiable {
    public var guestId: String
    /// The name the guest typed: a label, not proof.
    public var name: String
    public var joinedAt: UInt64
    /// `active`, `kicked` or `left`.
    public var state: String

    public var id: String { guestId }

    enum CodingKeys: String, CodingKey {
        case name, state
        case guestId = "guest_id"
        case joinedAt = "joined_at"
    }

    public init(guestId: String, name: String, joinedAt: UInt64, state: String) {
        self.guestId = guestId
        self.name = name
        self.joinedAt = joinedAt
        self.state = state
    }
}

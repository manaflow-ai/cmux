import Foundation

// Link shares of an agent chat (`agent-session-share-*`, cmux-tui-core
// server/agent_session_shares.rs; design chat-multiplayer.md 4.2): the owner shares one chat with
// a guest through a link that works a few times (once by default) and expires (24 h by default),
// and may invite cmux accounts to a share, who join after signing in.
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

/// `agent-session-share-room`: the room new links go to and the cmux API whose install token it takes
/// (cmux-tui `platform::share_owner_api`). The owner token for a create comes from that API, so a room
/// never gets another environment's token (cmux#31372).
public struct AgentSessionShareRoomRequest: DaemonRequest {
    public typealias Response = AgentSessionShareRoom
    public static let command = "agent-session-share-room"

    public init() {}
}

public struct AgentSessionShareRoom: Decodable, Sendable, Equatable {
    /// The room's origin; nil when the daemon has none (its links have no URL).
    public var room: String?
    /// The API the owner token must come from; nil for a room the daemon does not know.
    public var ownerApi: String?

    enum CodingKeys: String, CodingKey {
        case room
        case ownerApi = "owner_api"
    }

    public init(room: String?, ownerApi: String?) {
        self.room = room
        self.ownerApi = ownerApi
    }
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

/// `agent-session-share-invite`: the cmux account `account` (an email or `@handle`) may join the share
/// after signing in, as `role` (`view` watches, `talk` also sends held messages; the daemon's default
/// is `talk`). The same role again changes nothing; another role is refused (`share.invited`).
public struct AgentSessionShareInviteRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "agent-session-share-invite"

    public var shareId: String
    public var account: String
    public var role: String?

    public init(shareId: String, account: String, role: String? = nil) {
        self.shareId = shareId
        self.account = account
        self.role = role
    }
}

/// `agent-session-share-uninvite`: the account joins no more, and every guest it joined as leaves.
public struct AgentSessionShareUninviteRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "agent-session-share-uninvite"

    public var shareId: String
    public var account: String

    public init(shareId: String, account: String) {
        self.shareId = shareId
        self.account = account
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
    /// The link invitees open (`<room>/i/<share_id>`, no secret in it); nil without a room, and from a
    /// daemon older than invite links.
    public var inviteUrl: String?
    public var guests: [AgentSessionShareGuest]
    /// The cmux accounts invited to the share; empty from a daemon older than invites.
    public var invitees: [AgentSessionShareInvitee]

    public var id: String { shareId }
    public var isLive: Bool { state == "active" || state == "provisioning" }

    enum CodingKeys: String, CodingKey {
        case state, session, surface, room, guests, invitees
        case shareId = "share_id"
        case createdAt = "created_at"
        case createId = "create_id"
        case expiresAt = "expires_at"
        case expiresInSecs = "expires_in_secs"
        case usesLeft = "uses_left"
        case inviteUrl = "invite_url"
    }

    public init(shareId: String, state: String, session: String, surface: UInt64, createdAt: UInt64 = 0, createId: String? = nil,
                expiresAt: UInt64 = 0, expiresInSecs: UInt64 = 0, usesLeft: UInt32 = 0, room: String? = nil, inviteUrl: String? = nil,
                guests: [AgentSessionShareGuest] = [], invitees: [AgentSessionShareInvitee] = []) {
        self.shareId = shareId
        self.state = state
        self.session = session
        self.surface = surface
        self.createdAt = createdAt
        self.createId = createId
        self.expiresAt = expiresAt
        self.expiresInSecs = expiresInSecs
        self.usesLeft = usesLeft
        self.room = room
        self.inviteUrl = inviteUrl
        self.guests = guests
        self.invitees = invitees
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        shareId = try c.decode(String.self, forKey: .shareId)
        session = try c.decode(String.self, forKey: .session)
        surface = try c.decode(UInt64.self, forKey: .surface)
        createdAt = try c.decode(UInt64.self, forKey: .createdAt)
        createId = try c.decodeIfPresent(String.self, forKey: .createId)
        expiresAt = try c.decode(UInt64.self, forKey: .expiresAt)
        expiresInSecs = try c.decode(UInt64.self, forKey: .expiresInSecs)
        usesLeft = try c.decode(UInt32.self, forKey: .usesLeft)
        room = try c.decodeIfPresent(String.self, forKey: .room)
        inviteUrl = try c.decodeIfPresent(String.self, forKey: .inviteUrl)
        guests = try c.decode([AgentSessionShareGuest].self, forKey: .guests)
        invitees = try c.decodeIfPresent([AgentSessionShareInvitee].self, forKey: .invitees) ?? []
    }
}

/// An account the owner invited to a share.
public struct AgentSessionShareInvitee: Decodable, Sendable, Equatable, Identifiable {
    /// Trimmed and lowercased by the daemon: an email address or a cmux `@handle`.
    public var account: String
    /// `view` or `talk`.
    public var role: String
    public var invitedAt: UInt64
    /// `invited` or `removed`.
    public var state: String

    public var id: String { account }
    public var isInvited: Bool { state == "invited" }

    enum CodingKeys: String, CodingKey {
        case account, role, state
        case invitedAt = "invited_at"
    }

    public init(account: String, role: String, invitedAt: UInt64, state: String) {
        self.account = account
        self.role = role
        self.invitedAt = invitedAt
        self.state = state
    }
}

public struct AgentSessionShareGuest: Decodable, Sendable, Equatable, Identifiable {
    public var guestId: String
    /// The name the guest typed: a label, not proof.
    public var name: String
    public var joinedAt: UInt64
    /// `active`, `kicked` or `left`.
    public var state: String
    /// The invited account this guest joined as; nil for a link guest.
    public var account: String?
    /// The invited account's role (`view` or `talk`); nil for a link guest.
    public var role: String?

    public var id: String { guestId }

    enum CodingKeys: String, CodingKey {
        case name, state, account, role
        case guestId = "guest_id"
        case joinedAt = "joined_at"
    }

    public init(guestId: String, name: String, joinedAt: UInt64, state: String, account: String? = nil, role: String? = nil) {
        self.guestId = guestId
        self.name = name
        self.joinedAt = joinedAt
        self.state = state
        self.account = account
        self.role = role
    }
}

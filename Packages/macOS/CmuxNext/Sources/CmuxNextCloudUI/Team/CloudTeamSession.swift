public import CmuxNextActions
import Foundation

/// One of the team's Cloud workspaces or chats as TeamDO answers it (`CloudSessionView`,
/// backend/packages/protocol/src/team-cloud-session-ops.ts): the row the sidebar's Team section
/// draws and the record `cmux cloud team-session` prints.
public nonisolated struct CloudTeamSession: Identifiable, Equatable, Sendable {
    /// `cloud:<team>/<vm>/<id>` (contract C5).
    public var key: String
    public var team: String
    public var vm: String
    public var session: String
    public var kind: DeepLink.CloudSessionKind
    public var title: String
    public var owner: String
    public var ownerName: String?
    public var assignee: String
    public var assigneeName: String?
    /// running, asleep, waking, unresponsive or gone.
    public var machineState: String
    /// working, needs_attention or idle.
    public var activity: String
    public var lastActivityAt: Int
    public var archived: Bool
    public var followers: [String]
    public var followerCount: Int
    public var following: Bool
    public var assignedToYou: Bool
    public var viewers: [String]
    public var canReassign: Bool
    public var canArchive: Bool
    public var link: String

    public var id: String { key }

    /// A row from the reply, nil when a required field is missing or of the wrong type.
    public init?(_ json: [String: Any]) {
        guard let key = json["key"] as? String, let team = json["team"] as? String, let vm = json["vm"] as? String,
              let session = json["session"] as? String,
              let kind = (json["kind"] as? String).flatMap(DeepLink.CloudSessionKind.init(wireKind:)),
              let owner = json["owner"] as? String, let assignee = json["assignee"] as? String else { return nil }
        self.key = key
        self.team = team
        self.vm = vm
        self.session = session
        self.kind = kind
        title = json["title"] as? String ?? ""
        self.owner = owner
        ownerName = json["owner_name"] as? String
        self.assignee = assignee
        assigneeName = json["assignee_name"] as? String
        machineState = json["machine_state"] as? String ?? "running"
        activity = json["activity"] as? String ?? "idle"
        lastActivityAt = (json["last_activity_at"] as? NSNumber)?.intValue ?? 0
        archived = json["archived"] as? Bool ?? false
        followers = json["followers"] as? [String] ?? []
        followerCount = (json["follower_count"] as? NSNumber)?.intValue ?? followers.count
        following = json["following"] as? Bool ?? false
        assignedToYou = json["assigned_to_you"] as? Bool ?? false
        viewers = json["viewers"] as? [String] ?? []
        canReassign = json["can_reassign"] as? Bool ?? false
        canArchive = json["can_archive"] as? Bool ?? false
        link = json["link"] as? String ?? DeepLink(.cloudSession(team: team, machine: vm, session: session, kind: kind)).url(scheme: "cmux")?.absoluteString ?? ""
    }

    /// The link teammates open it with (`cmux://cloud/session|workspace/<team>/<vm>/<id>`).
    public var deepLink: DeepLink { DeepLink(.cloudSession(team: team, machine: vm, session: session, kind: kind)) }

    /// Whether `user` (the signed-in person) may follow it: a session assigned to them is already theirs.
    public var canFollow: Bool { !assignedToYou }
}

/// A member of the active team, as `team.members.list` answers one: whom Reassign to offers.
public nonisolated struct CloudTeamMember: Identifiable, Equatable, Sendable {
    public var user: String
    public var name: String
    /// owner, admin, member, billing or guest.
    public var role: String

    public var id: String { user }

    public init(user: String, name: String, role: String) {
        self.user = user
        self.name = name
        self.role = role
    }

    public init?(_ json: [String: Any]) {
        guard let user = json["user"] as? String else { return nil }
        self.init(user: user, name: (json["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? user, role: json["role"] as? String ?? "member")
    }

    /// A guest or a billing-only member is not someone work goes to: TeamDO refuses a reassign to one (`cloud_session.assignee_not_member`).
    public var canBeAssigned: Bool { role != "guest" && role != "billing" }
}

/// A refusal from the Team section's core: the backend's own code (`cloud_session.not_yours`,
/// `team.not_member`, …) or one of the client's below. The CLI prints it as
/// `{ok:false,error:{code,message}}`.
public nonisolated struct CloudTeamError: Error, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static let signedOut = "cloud.signed_out"
    public static let unreachable = "cloud.unreachable"
    /// The run named no team Cloud session and targets no Cloud workspace or chat.
    public static let notCloud = "cloud_session.not_cloud"
    /// `--session` is neither a `cloud:` key nor a `cmux://cloud/…` link.
    public static let invalidSession = "cloud_session.invalid"
    /// The link names a teammate's machine this Mac has no route to yet.
    public static let attachUnavailable = "cloud_session.attach_unavailable"
}

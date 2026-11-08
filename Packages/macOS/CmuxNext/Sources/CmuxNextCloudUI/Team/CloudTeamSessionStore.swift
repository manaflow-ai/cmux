public import CmuxNextActions
import Foundation
public import Observation

/// The team's Cloud workspaces and chats (cloud multiplayer, lane D): the one core path the
/// sidebar's Team section, the `cloud team-*` actions (so `cmux cloud …` and MCP) and the
/// publisher all go through. It speaks TeamDO's `team.cloud.session.*` and `group.members.*`
/// ops through `transport` (the app's signed-in `/v1/read` and `/v1/ops` call with `x-cmux-team`).
///
/// A Follow, Archive or Reassign changes the shown row on the same turn and rolls it back when
/// TeamDO refuses; the row TeamDO answers then replaces it. Replies to an older list (the person
/// switched filters while one was in flight) are dropped.
@MainActor @Observable
public final class CloudTeamSessionStore {
    /// One HTTP call: `path` is `v1/read` or `v1/ops`, `team` goes in `x-cmux-team` (nil: the
    /// account's active team). Throws ``CloudTeamError`` for a refusal it can name.
    public typealias Transport = @MainActor (_ path: String, _ body: [String: Any], _ team: String?) async throws -> [String: Any]

    /// The Team section's filters (Conductor's "Assigned to me / Team / Following / Archived").
    public nonisolated enum Filter: String, CaseIterable, Sendable {
        case mine, team, following, archived

        /// `team.cloud.session.list`'s scope for it.
        public var scope: String { self == .archived ? "team" : rawValue }

        /// Whether `session` belongs under this filter: what a changed row is checked against.
        public func includes(_ session: CloudTeamSession) -> Bool {
            switch self {
            case .mine: !session.archived && session.assignedToYou
            case .team: !session.archived
            case .following: !session.archived && session.following
            case .archived: session.archived
            }
        }
    }

    /// Which session an action names: its team, machine and id on the machine.
    public nonisolated struct Ref: Equatable, Sendable {
        public var team: String
        public var vm: String
        public var session: String
        public var kind: DeepLink.CloudSessionKind

        public init(team: String, vm: String, session: String, kind: DeepLink.CloudSessionKind = .chat) {
            self.team = team
            self.vm = vm
            self.session = session
            self.kind = kind
        }

        /// A `cloud:<team>/<vm>/<id>` key or a `cmux://cloud/…` link; nil for anything else.
        public init?(_ text: String) {
            guard let link = DeepLink.cloudSession(text), case .cloudSession(let team, let vm, let session, let kind) = link.target else { return nil }
            self.init(team: team, vm: vm, session: session, kind: kind)
        }

        public var key: String { "cloud:\(team)/\(vm)/\(session)" }
        var params: [String: Any] { ["vm": vm, "session": session] }
    }

    public private(set) var filter: Filter = .mine
    /// The rows under ``filter``, most recently active first.
    public private(set) var sessions: [CloudTeamSession] = []
    /// The active team's members, for Reassign to (``loadMembers()``).
    public private(set) var members: [CloudTeamMember] = []
    public private(set) var isLoading = false
    /// The team the rows are of (the account's active team, ``setTeam(_:)``); the section reloads when it changes.
    public private(set) var team: String?
    /// Why the last list failed, nil after one that answered.
    public private(set) var listError: CloudTeamError?

    @ObservationIgnored private let transport: Transport
    @ObservationIgnored private let makeKey: () -> String
    @ObservationIgnored private var listGeneration = 0
    /// The signed-in person's TeamDO user id (`user_…`): a reassign to them shows under Assigned to me at once.
    @ObservationIgnored public var currentUser: () -> String?
    /// The account's active team: every call that names no team goes to it (`x-cmux-team`), the
    /// team the publisher writes to, never the Worker's personal-team default.
    @ObservationIgnored public var activeTeam: () -> String?

    public init(transport: @escaping Transport, currentUser: @escaping () -> String? = { nil },
                activeTeam: @escaping () -> String? = { nil }, idempotencyKey: (() -> String)? = nil) {
        self.transport = transport
        self.currentUser = currentUser
        self.activeTeam = activeTeam
        makeKey = idempotencyKey ?? { "cloud-team-\(UUID().uuidString)" }
    }

    // MARK: Reads

    /// The account switched teams (or signed out): the old team's rows and members go, and a list
    /// of the old team still in flight is dropped when it answers.
    public func setTeam(_ next: String?) {
        guard next != team else { return }
        team = next
        listGeneration += 1
        sessions = []
        members = []
        listError = nil
        isLoading = false
    }

    /// Shows `filter`'s rows: the ones already loaded that belong there on this turn, then the list.
    public func select(_ filter: Filter) async {
        self.filter = filter
        sessions = sessions.filter(filter.includes)
        await refresh()
    }

    /// Lists ``filter`` again. A failure keeps the rows shown and sets ``listError`` (only while
    /// no later list of the section was started: ``list(scope:by:archived:cursor:limit:team:)``).
    public func refresh() async {
        _ = try? await list(scope: filter.scope, archived: filter == .archived)
    }

    /// `team.cloud.session.list`'s value (`{team, sessions, next_cursor}`). A first page of the
    /// shown filter (no `by`, no cursor) also becomes ``sessions``.
    @discardableResult
    public func list(scope: String = "team", by: String? = nil, archived: Bool = false, cursor: String? = nil,
                     limit: Int? = nil, team: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["scope": scope]
        if let by { params["by"] = by }
        if archived { params["archived"] = true }
        if let cursor { params["cursor"] = cursor }
        if let limit { params["limit"] = limit }
        let resolved = team ?? activeTeam()
        // The section's own list: its filter's first page in the active team. Only these count
        // generations, so a script's page (`--by`, `--cursor`, another team) never drops it.
        let shown = by == nil && cursor == nil && resolved == activeTeam() && scope == filter.scope && archived == (filter == .archived)
        guard shown else { return try await read("team.cloud.session.list", params, team: resolved) }
        listGeneration += 1
        let generation = listGeneration
        isLoading = true
        defer { if generation == listGeneration { isLoading = false } }
        do {
            let value = try await read("team.cloud.session.list", params, team: resolved)
            if generation == listGeneration {
                let rows = (value["sessions"] as? [[String: Any]] ?? []).compactMap(CloudTeamSession.init)
                sessions = rows.filter(filter.includes)
                listError = nil
            }
            return value
        } catch {
            if generation == listGeneration {
                listError = error as? CloudTeamError ?? CloudTeamError(code: CloudTeamError.unreachable, message: CloudTeamStrings.unreachable)
            }
            throw error
        }
    }

    /// `team.cloud.session.get`'s value (`{session}`); the row also refreshes the shown one.
    public func get(_ ref: Ref) async throws -> [String: Any] {
        let value = try await read("team.cloud.session.get", ref.params, team: ref.team)
        if let row = (value["session"] as? [String: Any]).flatMap(CloudTeamSession.init) { apply(row) }
        return value
    }

    /// The active team's members (`team.members.list`), guests last; also ``members``.
    @discardableResult
    public func loadMembers() async throws -> [CloudTeamMember] {
        let value = try await read("team.members.list", ["limit": 200], team: activeTeam())
        let all = (value["members"] as? [[String: Any]] ?? []).compactMap(CloudTeamMember.init)
        members = all.filter(\.canBeAssigned) + all.filter { !$0.canBeAssigned }
        return members
    }

    // MARK: Changes (shown at once, rolled back on a refusal)

    /// Follows or stops following `ref`; answers TeamDO's row.
    public func setFollowing(_ ref: Ref, _ follow: Bool) async throws -> [String: Any] {
        try await change(ref, op: "team.cloud.session.follow", params: ["follow": follow]) { row in
            guard row.following != follow else { return }
            row.following = follow
            row.followerCount = max(0, row.followerCount + (follow ? 1 : -1))
        }
    }

    /// Archives `ref` for the team, or brings it back.
    public func setArchived(_ ref: Ref, _ archived: Bool) async throws -> [String: Any] {
        try await change(ref, op: "team.cloud.session.archive", params: ["archived": archived]) { $0.archived = archived }
    }

    /// Assigns `ref` to member `user`.
    public func reassign(_ ref: Ref, to user: String) async throws -> [String: Any] {
        let me = currentUser()
        let name = members.first { $0.user == user }?.name
        return try await change(ref, op: "team.cloud.session.reassign", params: ["to": user]) { row in
            // The previous assignee follows it (TeamDO does the same).
            if row.assignedToYou, !row.following, user != me {
                row.following = true
                row.followerCount += 1
            }
            row.assignee = user
            row.assigneeName = name ?? row.assigneeName
            row.assignedToYou = user == me
        }
    }

    /// Publishes one of the person's Cloud workspaces or chats (`team.cloud.session.publish`).
    public func publish(_ ref: Ref, title: String, workspace: String?, harness: String?, machineState: String,
                        activity: String, lastActivityAt: Int) async throws -> [String: Any] {
        var params = ref.params
        params["kind"] = ref.kind.wireKind
        // TeamDO caps a title at 200 UTF-16 units; cut on a character boundary under that.
        var cut = title
        while cut.utf16.count > 200 { cut.removeLast() }
        params["title"] = cut
        if let workspace, ref.kind == .chat { params["workspace"] = workspace }
        // TeamDO takes a harness name of lowercase letters, digits and `-` only; another one is left out.
        if let harness, (1...64).contains(harness.utf8.count),
           harness.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == UInt8(ascii: "-") }) {
            params["harness"] = harness
        }
        params["machine_state"] = machineState
        params["activity"] = activity
        params["last_activity_at"] = lastActivityAt
        let value = try await mutate("team.cloud.session.publish", params, team: ref.team)
        if let row = CloudTeamSession(value) { apply(row) }
        return value
    }

    // MARK: Cloud group members

    public func groupMembers(_ group: String) async throws -> [String: Any] {
        try await read("group.members.list", ["group": group], team: activeTeam())
    }

    public func setGroupMember(_ group: String, user: String, role: String) async throws -> [String: Any] {
        try await mutate("group.members.set", ["group": group, "user": user, "role": role], team: activeTeam())
    }

    public func removeGroupMember(_ group: String, user: String) async throws -> [String: Any] {
        try await mutate("group.members.remove", ["group": group, "user": user], team: activeTeam())
    }

    // MARK: Core

    /// Puts `row` where ``filter`` says: replaced in place, inserted by its activity, or removed.
    public func apply(_ row: CloudTeamSession) {
        let index = sessions.firstIndex { $0.key == row.key }
        guard filter.includes(row) else {
            if let index { sessions.remove(at: index) }
            return
        }
        if let index {
            sessions[index] = row
        } else {
            let at = sessions.firstIndex { $0.lastActivityAt < row.lastActivityAt } ?? sessions.endIndex
            sessions.insert(row, at: at)
        }
    }

    /// The shown row of `ref`, if it shows.
    public func row(_ ref: Ref) -> CloudTeamSession? {
        sessions.first { $0.key == ref.key }
    }

    private func change(_ ref: Ref, op: String, params: [String: Any],
                        _ local: (inout CloudTeamSession) -> Void) async throws -> [String: Any] {
        let before = row(ref)
        var optimistic: CloudTeamSession?
        if var shown = before {
            local(&shown)
            optimistic = shown
            apply(shown)
        }
        do {
            let value = try await mutate(op, ref.params.merging(params) { $1 }, team: ref.team)
            if let row = CloudTeamSession(value) { apply(row) }
            return value
        } catch {
            // Undo only our own change: a list or a later change that replaced the row wins.
            // (Under a filter the optimistic row left, nothing shows for it, so it comes back.)
            if let before, let optimistic, row(ref) == (filter.includes(optimistic) ? optimistic : nil) { apply(before) }
            throw error
        }
    }

    private func read(_ op: String, _ params: [String: Any], team: String?) async throws -> [String: Any] {
        try Self.value(try await transport("v1/read", ["op": op, "params": params], team))
    }

    private func mutate(_ op: String, _ params: [String: Any], team: String?) async throws -> [String: Any] {
        let body: [String: Any] = ["op": op, "params": params, "idempotency_key": makeKey(), "origin": "user"]
        return try Self.value(try await transport("v1/ops", body, team))
    }

    /// An op reply's value: `{value}`; a Worker refusal (`{_tag, code, message}` or
    /// `{error: {code, message}}`) throws its code.
    nonisolated static func value(_ reply: [String: Any]) throws -> [String: Any] {
        if let error = reply["error"] as? [String: Any] {
            throw CloudTeamError(code: error["code"] as? String ?? "error", message: error["message"] as? String ?? "")
        }
        if reply["_tag"] != nil, let code = reply["code"] as? String {
            throw CloudTeamError(code: code, message: reply["message"] as? String ?? code)
        }
        guard let value = reply["value"] as? [String: Any] else {
            throw CloudTeamError(code: CloudTeamError.unreachable, message: "The Cloud service sent an unexpected reply.")
        }
        return value
    }
}

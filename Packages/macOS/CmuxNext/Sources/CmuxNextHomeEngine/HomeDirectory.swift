public import CmuxHomeCore
import CmuxNextCloud
import CmuxNextCompat
public import CmuxNextHome
import Foundation
public import Observation

/// The people and Chiefs behind the Home page's New Message and New Chief
/// (home-messaging.md 4.2 and 16): the members of the active team (its TeamDO's
/// `team.members.list`; one team at a time) and the user's Chiefs (UserDO `chief.*`).
/// Reads and writes go to the API Worker as the signed-in user through
/// `call` (`FeedService.call`, whose origin is `FeedService.apiBaseURL`,
/// `CMUX_NEXT_FEED_API_URL` overrides it), like Add Server's pairing.
/// Conversations themselves never go through here: they stay with
/// HomeStore and the daemon's cloud proxy. The App's `HomeService` owns one.
@Observable @MainActor
public final class HomeDirectory {
    /// One Worker call as the signed-in user: a path (`v1/read`, `v1/ops`) and its JSON body.
    public typealias Call = @MainActor (_ path: String, _ body: [String: Any]) async throws -> [String: Any]
    /// `call` acting in `team` (`x-cmux-team`); a session acts in its personal team otherwise.
    public typealias TeamCall = @MainActor (_ path: String, _ body: [String: Any], _ team: String) async throws -> [String: Any]

    /// The active team's members (``refresh()``), without me.
    public var teamMembers: [HomeContact] = []
    /// My active cloud Chiefs (`chief.list`).
    public private(set) var chiefs: [HomeChiefRecord] = []
    /// My archived and deleted Chiefs' agent ids: the page hides their conversations.
    public var archivedChiefs: Set<String> { hiddenCloudChiefs.union(deletedLocalChiefs).union(chiefArchive.hidden) }
    /// My cloud Chiefs that are archived or deleted (`chief.list` with its tombstones).
    private var hiddenCloudChiefs: Set<String> = []
    /// Archive Chief's cloud Chiefs hidden on this Mac until their cloud archive lands (``HomeChiefArchive``).
    public let chiefArchive: HomeChiefArchive
    /// This Mac's deleted Chiefs (the owner's `chief.profile.list` `deleted`), read with their engines.
    public var deletedLocalChiefs: Set<String> = []
    /// Each of this Mac's Chiefs' own avatar for its list tile, by participant id, the one
    /// its header shows: read by `HomeService.refreshChiefAvatars()` (again after the
    /// header's avatar picker). A Chief not listed draws the bundled default.
    public var chiefAvatars: [String: HomeChiefAvatar] = [:]
    /// The engine each of this Mac's Chiefs runs on, by participant id (a Chief on the brain's
    /// own default is not listed), for the Home list's badges: read by `HomeService.refreshChiefHarnesses()`.
    public var chiefHarnesses: [String: String] = [:]
    @ObservationIgnored private let call: Call
    @ObservationIgnored private let teamCall: TeamCall?
    /// The signed-in account's Worker user id (`CloudIdentity.workerUserID`), left out of the contacts.
    @ObservationIgnored private let me: @MainActor () -> String?
    /// The active team's Worker team id (`ActiveTeam`, `CloudIdentity.workerTeamID`), or nil before one loads.
    @ObservationIgnored private let activeTeam: @MainActor () -> String?

    /// `call` and `teamCall` reach the Worker; `activeTeam` and `me` name the active team and the signed-in user.
    public init(call: @escaping Call, teamCall: TeamCall? = nil, activeTeam: @escaping @MainActor () -> String? = { nil },
         me: @escaping @MainActor () -> String?, chiefArchive: HomeChiefArchive = HomeChiefArchive()) {
        self.call = call
        self.teamCall = teamCall
        self.activeTeam = activeTeam
        self.me = me
        self.chiefArchive = chiefArchive
    }

    /// Reads the team and the Chiefs again each time the signed-in session changes: `session` is
    /// a key of the account, its active team and its teams (`user|team|teams`), nil while signed
    /// out or while the stored sign-in is still being restored at launch. Home's first read runs
    /// before that restore ends and fails as signed out, so without this the team stayed unlisted
    /// until a New Message was opened. Signing out (nil), another account or another active team
    /// (Switch Active Team) drops the last team's people at once: Home lists one team at a time.
    public func follow(session: @escaping @MainActor @Sendable () -> String?) {
        sessionWatch?.cancel()
        // task-owner: lives as long as the directory (HomeService's); event-driven (Observation)
        sessionWatch = Task { [weak self] in
            var scope: [Substring]?
            for await key in ObservationStream(session) {
                guard let self else { return }
                let next = key.map { Array($0.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).prefix(2)) }
                if next != scope { teamMembers = [] }
                scope = next
                if key != nil { await refresh() }
            }
        }
    }

    @ObservationIgnored private var sessionWatch: Task<Void, Never>?

    /// Reads the team members and the Chiefs again; a read that fails keeps
    /// the last list (signed out, offline). A read that lands after the active team changed is
    /// dropped: the newer team's read replaces it.
    public func refresh() async {
        let team = activeTeam()
        if let members = await readTeamMembers(team: team), activeTeam() == team { teamMembers = members }
        await refreshChiefs()
    }

    /// The members of the active team (the user, 2026-10-29: "should only show for a team at a
    /// time… no multi team"), each person once; with no active team yet, the personal team's.
    /// `user.teams.list` runs first because it mirrors a Stack team its webhook never synced
    /// (72ca5bb), so a new team's members are there to read. A team whose role may not list
    /// members (a guest), or whose read fails, gives nil: never another team's people.
    private func readTeamMembers(team: String?) async -> [HomeContact]? {
        let body: [String: Any] = ["op": "team.members.list", "params": ["limit": 200]]
        let value: Any?
        if let team, let teamCall {
            _ = try? await call("v1/read", ["op": "user.teams.list", "params": [String: Any]()])
            guard let read = try? Self.value(try await teamCall("v1/read", body, team)) else { return nil }
            value = read
        } else {
            guard let read = try? Self.value(try await call("v1/read", body)) else { return nil }
            value = read
        }
        var seen = Set<ParticipantID>()
        return Self.members(from: value, excluding: me()).filter { seen.insert($0.id).inserted }
    }

    /// Reads the Chiefs; then each Chief archived here while offline gets its cloud archive.
    public func refreshChiefs() async {
        if await readChiefs() { await chiefArchive.sync(archiveAccount) }
    }

    /// Archive Chief on one of my cloud Chiefs (``HomeChiefArchive``).
    public func archiveChief(_ id: String) async -> HomeChiefArchive.Outcome {
        await chiefArchive.archive(id, in: archiveAccount)
    }

    /// This account's Chiefs and its `chief.archive` call, for ``HomeChiefArchive``.
    private var archiveAccount: HomeChiefArchive.Account {
        HomeChiefArchive.Account(
            chiefs: { [weak self] in self?.chiefs ?? [] }, gone: { [weak self] in self?.hiddenCloudChiefs ?? [] },
            listed: { [weak self] in self?.chiefsRead ?? false },
            archive: { [weak self] record in await self?.cloudArchive(record) ?? .unreachable },
            reread: { [weak self] in await self?.readChiefs() ?? false },
            archived: { [weak self] id in
                self?.chiefs.removeAll { $0.id == id }
                self?.hiddenCloudChiefs.insert(id)
            })
    }

    /// `chief.archive` at the record's revision (history stays read-only).
    private func cloudArchive(_ record: HomeChiefRecord) async -> HomeChiefArchive.Reply {
        let body: [String: Any] = ["op": "chief.archive", "params": ["chief": record.id, "expected_rev": record.rev],
                                   "idempotency_key": "chief-archive-\(record.id)-\(record.rev)", "origin": "user"]
        do {
            _ = try Self.value(try await call("v1/ops", body))
            return .archived
        } catch FeedServiceError.owner(let code, let message) {
            switch code {
            case "revision.conflict": return .conflict
            case "chief_is_default": return .isDefault
            case "selector.not_found": return .notFound
            default: return .refused(message)
            }
        } catch {
            return .unreachable
        }
    }

    /// `chief.list` with the archived ones; false when it did not answer (the last list stays).
    public func readChiefs() async -> Bool {
        guard let reply = try? await call("v1/read", ["op": "chief.list", "params": ["include_archived": true]]),
              let value = try? Self.value(reply) else { return false }
        chiefs = HomeChiefRecord.list(from: value)
        hiddenCloudChiefs = HomeChiefRecord.archivedIDs(from: value)
        chiefsRead = true
        return true
    }

    /// `chief.list` answered this launch; until then `archivedChiefs` may be the last launch's.
    @ObservationIgnored public private(set) var chiefsRead = false

    /// The last launch's list state (`HomeSidebarLaunchSnapshot`), for what has not been read yet:
    /// the list's first frame hides the same archived Chiefs and draws the same avatars and tags.
    public func seedLaunch(_ snapshot: HomeSidebarLaunchSnapshot) {
        if !chiefsRead, hiddenCloudChiefs.isEmpty { hiddenCloudChiefs = snapshot.archivedChiefs }
        if chiefAvatars.isEmpty { chiefAvatars = snapshot.chiefAvatars }
        if chiefHarnesses.isEmpty { chiefHarnesses = snapshot.chiefHarnesses }
    }

    /// `chief.create` with a display name; the new Chief's main conversation
    /// reaches the inbox through the owner (UserDO's outbox).
    public func createChief(named name: String) async throws -> HomeChiefRecord {
        // A new key per attempt: the owner keeps a refused key's answer, so a
        // retry after user.ensure under the same key would replay the refusal.
        let value = try await ensuringUser {
            let body: [String: Any] = ["op": "chief.create", "params": ["display_name": name],
                                       "idempotency_key": "chief-create-" + UUID().uuidString.lowercased(), "origin": "user"]
            return try Self.value(try await self.call("v1/ops", body))
        }
        guard let record = HomeChiefRecord.parse(value) else { throw FeedServiceError.badReply }
        chiefs.removeAll { $0.id == record.id }
        chiefs.append(record)
        return record
    }

    /// `chief.delete` at the record's revision: the Chief goes for good (only its tombstone stays),
    /// and its conversation leaves the list as an archived one's does.
    public func deleteChief(_ id: String) async throws {
        guard let record = chiefs.first(where: { $0.id == id }) else { throw FeedServiceError.owner(code: "selector.not_found", message: id) }
        let body: [String: Any] = ["op": "chief.delete", "params": ["chief": id, "expected_rev": record.rev],
                                   "idempotency_key": "chief-delete-\(id)-\(record.rev)", "origin": "user"]
        _ = try Self.value(try await call("v1/ops", body))
        chiefs.removeAll { $0.id == id }
        hiddenCloudChiefs.insert(id)
    }

    /// Renames the cloud Chief whose main conversation is `conversation`: `chief.update
    /// {display_name}` at the record's revision. UserDO then renames its main conversation too
    /// (`chief.rename`: the title and the Chief's name there). One revision conflict (another
    /// device changed the Chief) reads the list again and retries once. Nil when the name was
    /// saved, else why it was not.
    public func renameChief(conversation: String, to name: String) async -> HomeChiefRenameFailure? {
        for attempt in 0..<2 {
            if attempt > 0 || !chiefs.contains(where: { $0.mainConversation == conversation }) {
                do {
                    let value = try Self.value(try await call("v1/read", ["op": "chief.list", "params": ["include_archived": true]]))
                    chiefs = HomeChiefRecord.list(from: value)
                    hiddenCloudChiefs = HomeChiefRecord.archivedIDs(from: value)
                } catch {
                    return Self.renameFailure(error)
                }
            }
            guard let record = chiefs.first(where: { $0.mainConversation == conversation }) else { return .notFound }
            let body: [String: Any] = ["op": "chief.update", "origin": "user",
                                       "idempotency_key": "chief-rename-\(record.id)-\(record.rev)-\(UUID().uuidString.lowercased())",
                                       "params": ["chief": record.id, "expected_rev": record.rev, "display_name": name]]
            do {
                let value = try Self.value(try await call("v1/ops", body))
                var renamed = HomeChiefRecord.parse(value) ?? record
                if HomeChiefRecord.parse(value) == nil {
                    renamed.name = name
                    renamed.rev += 1
                }
                chiefs = chiefs.map { $0.id == renamed.id ? renamed : $0 }
                return nil
            } catch FeedServiceError.owner(code: "revision.conflict", message: _) where attempt == 0 {
                continue
            } catch {
                return Self.renameFailure(error)
            }
        }
        return .changedElsewhere
    }

    /// The card's reason for an error of `call` or of the owner.
    public static func renameFailure(_ error: any Error) -> HomeChiefRenameFailure {
        switch error {
        case FeedServiceError.signedOut: .signedOut
        case FeedServiceError.owner(code: "revision.conflict", _): .changedElsewhere
        case FeedServiceError.owner(code: "validation.invalid", _): .invalidName
        case FeedServiceError.owner(code: "selector.not_found", _), FeedServiceError.owner(code: "chief_archived", _): .notFound
        case FeedServiceError.owner(let code, let message): .refused(message.isEmpty ? code : message)
        // No answer, or one that could not be read: the card's "try again in a moment".
        default: .noConnection
        }
    }

    /// Runs `op`; UserDO refuses user ops of an account that never ran
    /// `user.ensure` ("call user.ensure first", seen on staging): then
    /// ensures the user (idempotent) and runs `op` once more.
    private func ensuringUser<T>(_ op: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch FeedServiceError.owner(let code, let message) where code == "validation.invalid" && message.contains("user.ensure") {
            let ensure: [String: Any] = ["op": "user.ensure", "params": [String: Any](),
                                         "idempotency_key": "home-user-ensure-" + UUID().uuidString.lowercased(), "origin": "user"]
            _ = try Self.value(try await call("v1/ops", ensure))
            return try await op()
        }
    }

    /// The Chief whose agent id is `participant`, when it is one of mine.
    public func chief(for participant: ParticipantID) -> HomeChiefRecord? {
        chiefs.first { $0.id == participant.rawValue }
    }

    // MARK: Replies

    /// The reply's `value`; a Worker error reply (`{_tag, code, message}`) throws.
    static func value(_ reply: [String: Any]) throws -> Any? {
        if reply["_tag"] != nil, let code = reply["code"] as? String {
            throw FeedServiceError.owner(code: code, message: reply["message"] as? String ?? code)
        }
        return reply["value"]
    }

    static func members(from value: Any?, excluding me: String?) -> [HomeContact] {
        let list = (value as? [String: Any])?["members"] as? [[String: Any]] ?? []
        return list.compactMap { member -> HomeContact? in
            guard let user = member["user"] as? String, !user.isEmpty else { return nil }
            let id = CloudIdentity.cloudID(stackUserID: user)
            guard id != me.map({ CloudIdentity.cloudID(stackUserID: $0) }) else { return nil }
            let name = (member["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? user
            return HomeContact(id: ParticipantID(id), name: name, source: .team)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

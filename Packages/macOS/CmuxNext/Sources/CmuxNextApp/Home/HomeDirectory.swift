import CmuxHomeCore
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHostedChief
import Foundation
import Observation

/// The people and Chiefs behind the Home page's New Message and New Chief
/// (home-messaging.md 4.2 and 16): the members of every team the user is in
/// (UserDO `user.teams.list`, then each TeamDO's `team.members.list`) and the
/// user's Chiefs (UserDO `chief.*`).
/// Reads and writes go to the API Worker as the signed-in user through
/// `call` (`FeedService.call`, whose origin is `FeedService.apiBaseURL`,
/// `CMUX_NEXT_FEED_API_URL` overrides it), like Add Server's pairing.
/// Conversations themselves never go through here: they stay with
/// HomeStore and the daemon's cloud proxy.
@Observable @MainActor
final class HomeDirectory {
    typealias Call = @MainActor (_ path: String, _ body: [String: Any]) async throws -> [String: Any]
    /// `call` acting in `team` (`x-cmux-team`); a session acts in its personal team otherwise.
    typealias TeamCall = @MainActor (_ path: String, _ body: [String: Any], _ team: String) async throws -> [String: Any]

    var teamMembers: [HomeContact] = []
    private(set) var chiefs: [HomeChiefRecord] = []
    /// My archived and deleted Chiefs' agent ids: the page hides their conversations.
    var archivedChiefs: Set<String> { hiddenCloudChiefs.union(deletedLocalChiefs) }
    /// My cloud Chiefs that are archived or deleted (`chief.list` with its tombstones).
    private var hiddenCloudChiefs: Set<String> = []
    /// This Mac's deleted Chiefs (the owner's `chief.profile.list` `deleted`), read with their engines.
    var deletedLocalChiefs: Set<String> = []
    /// Each of this Mac's Chiefs' own avatar for its list tile, by participant id, the one
    /// its header shows: read by `HomeService.refreshChiefAvatars()` (again after the
    /// header's avatar picker). A Chief not listed draws the bundled default.
    var chiefAvatars: [String: HomeChiefAvatar] = [:]
    /// The engine each of this Mac's Chiefs runs on, by participant id (a Chief on the brain's
    /// own default is not listed), for the Home list's badges: read by `HomeService.refreshChiefHarnesses()`.
    var chiefHarnesses: [String: String] = [:]
    @ObservationIgnored private let call: Call
    @ObservationIgnored private let teamCall: TeamCall?
    /// The signed-in account's Worker user id (`CloudIdentity.workerUserID`), left out of the contacts.
    @ObservationIgnored private let me: @MainActor () -> String?

    init(call: @escaping Call, teamCall: TeamCall? = nil, me: @escaping @MainActor () -> String?) {
        self.call = call
        self.teamCall = teamCall
        self.me = me
    }

    /// Reads the team members and the Chiefs again; a read that fails keeps
    /// the last list (signed out, offline).
    func refresh() async {
        if let members = await readTeamMembers() { teamMembers = members }
        await refreshChiefs()
    }

    /// The members of the personal team and of each shared team `user.teams.list` names, each
    /// person once. Home chats are not team-scoped and the Worker's reach rule checks every
    /// team of the user, so a teammate from any team can be messaged. A team whose role may not
    /// list members (a guest) is left out; nil when the personal team's list fails.
    private func readTeamMembers() async -> [HomeContact]? {
        let body: [String: Any] = ["op": "team.members.list", "params": ["limit": 200]]
        guard let personal = try? Self.value(try await call("v1/read", body)) else { return nil }
        var lists = [Self.members(from: personal, excluding: me())]
        if let teamCall,
           let teams = try? Self.value(try await call("v1/read", ["op": "user.teams.list", "params": [String: Any]()])) {
            for team in Self.sharedTeams(from: teams) {
                guard let value = try? Self.value(try await teamCall("v1/read", body, team)) else { continue }
                lists.append(Self.members(from: value, excluding: me()))
            }
        }
        var seen = Set<ParticipantID>()
        return lists.joined().filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The shared (not personal) team ids of a `user.teams.list` value.
    static func sharedTeams(from value: Any?) -> [String] {
        let list = (value as? [String: Any])?["teams"] as? [[String: Any]] ?? []
        return list.compactMap { team in
            guard let id = team["id"] as? String, !id.isEmpty, team["kind"] as? String != "personal" else { return nil }
            return id
        }
    }

    func refreshChiefs() async {
        if let reply = try? await call("v1/read", ["op": "chief.list", "params": ["include_archived": true]]),
           let value = try? Self.value(reply) {
            chiefs = HomeChiefRecord.list(from: value)
            hiddenCloudChiefs = HomeChiefRecord.archivedIDs(from: value)
            chiefsRead = true
        }
    }

    /// `chief.list` answered this launch; until then `archivedChiefs` may be the last launch's.
    @ObservationIgnored private(set) var chiefsRead = false

    /// The last launch's list state (`HomeSidebarLaunchSnapshot`), for what has not been read yet:
    /// the list's first frame hides the same archived Chiefs and draws the same avatars and tags.
    func seedLaunch(_ snapshot: HomeSidebarLaunchSnapshot) {
        if !chiefsRead, hiddenCloudChiefs.isEmpty { hiddenCloudChiefs = snapshot.archivedChiefs }
        if chiefAvatars.isEmpty { chiefAvatars = snapshot.chiefAvatars }
        if chiefHarnesses.isEmpty { chiefHarnesses = snapshot.chiefHarnesses }
    }

    /// `chief.create` with a display name; the new Chief's main conversation
    /// reaches the inbox through the owner (UserDO's outbox).
    func createChief(named name: String) async throws -> HomeChiefRecord {
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

    /// `chief.archive` at the record's revision (history stays read-only).
    func archiveChief(_ id: String) async throws {
        guard let record = chiefs.first(where: { $0.id == id }) else { throw FeedServiceError.owner(code: "selector.not_found", message: id) }
        let body: [String: Any] = ["op": "chief.archive", "params": ["chief": id, "expected_rev": record.rev],
                                   "idempotency_key": "chief-archive-\(id)-\(record.rev)", "origin": "user"]
        _ = try Self.value(try await call("v1/ops", body))
        chiefs.removeAll { $0.id == id }
        hiddenCloudChiefs.insert(id)
    }

    /// `chief.delete` at the record's revision: the Chief goes for good (only its tombstone stays),
    /// and its conversation leaves the list as an archived one's does.
    func deleteChief(_ id: String) async throws {
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
    func renameChief(conversation: String, to name: String) async -> HomeChiefRenameFailure? {
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
    static func renameFailure(_ error: any Error) -> HomeChiefRenameFailure {
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
    func chief(for participant: ParticipantID) -> HomeChiefRecord? {
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

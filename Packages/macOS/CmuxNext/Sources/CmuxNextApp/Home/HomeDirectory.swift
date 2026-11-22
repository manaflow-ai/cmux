import CmuxHomeCore
import CmuxNextHome
import Foundation
import Observation

/// One of the user's Chiefs, as UserDO's `chief.list` reports it.
struct HomeChiefRecord: Hashable, Sendable {
    var id: String
    var name: String
    var isDefault: Bool
    var rev: Int
    var mainConversation: String?
}

/// The people and Chiefs behind the Home page's New Message and New Chief
/// (home-messaging.md 4.2 and 16): the members of the user's team
/// (TeamDO `team.members.list`) and the user's Chiefs (UserDO `chief.*`).
/// Reads and writes go to the API Worker as the signed-in user through
/// `call` (`FeedService.call`, whose origin is `FeedService.apiBaseURL`,
/// `CMUX_NEXT_FEED_API_URL` overrides it), like Add Server's pairing.
/// Conversations themselves never go through here: they stay with
/// HomeStore and the daemon's cloud proxy.
@Observable @MainActor
final class HomeDirectory {
    typealias Call = @MainActor (_ path: String, _ body: [String: Any]) async throws -> [String: Any]

    private(set) var teamMembers: [HomeContact] = []
    private(set) var chiefs: [HomeChiefRecord] = []
    /// My archived Chiefs' agent ids: the page hides their conversations.
    private(set) var archivedChiefs: Set<String> = []
    @ObservationIgnored private let call: Call
    /// The signed-in account's Worker user id (`CloudIdentity.workerUserID`), left out of the contacts.
    @ObservationIgnored private let me: @MainActor () -> String?

    init(call: @escaping Call, me: @escaping @MainActor () -> String?) {
        self.call = call
        self.me = me
    }

    /// Reads the team members and the Chiefs again; a read that fails keeps
    /// the last list (signed out, offline).
    func refresh() async {
        if let reply = try? await call("v1/read", ["op": "team.members.list", "params": ["limit": 200]]),
           let value = try? Self.value(reply) {
            teamMembers = Self.members(from: value, excluding: me())
        }
        await refreshChiefs()
    }

    func refreshChiefs() async {
        if let reply = try? await call("v1/read", ["op": "chief.list", "params": ["include_archived": true]]),
           let value = try? Self.value(reply) {
            chiefs = Self.chiefs(from: value)
            archivedChiefs = Self.archivedChiefIDs(from: value)
        }
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
        guard let record = Self.chief(value) else { throw FeedServiceError.badReply }
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
        archivedChiefs.insert(id)
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

    static func chiefs(from value: Any?) -> [HomeChiefRecord] {
        ((value as? [String: Any])?["chiefs"] as? [[String: Any]] ?? []).compactMap(chief)
    }

    static func archivedChiefIDs(from value: Any?) -> Set<String> {
        let list = (value as? [String: Any])?["chiefs"] as? [[String: Any]] ?? []
        return Set(list.compactMap { $0["archived_at"] is String ? $0["id"] as? String : nil })
    }

    static func chief(_ value: Any?) -> HomeChiefRecord? {
        guard let object = value as? [String: Any], let id = object["id"] as? String,
              (object["archived_at"] as? String) == nil else { return nil }
        return HomeChiefRecord(id: id, name: object["display_name"] as? String ?? "", isDefault: object["is_default"] as? Bool ?? false,
                               rev: (object["rev"] as? NSNumber)?.intValue ?? 0, mainConversation: object["main_conversation"] as? String)
    }
}

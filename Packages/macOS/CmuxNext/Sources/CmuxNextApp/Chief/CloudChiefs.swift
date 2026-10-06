import Foundation

/// One of the user's cloud chiefs (`chief.list`, `HomeChief`), the fields the
/// app reads. `brainPlace` names the paired server whose install answers as
/// this chief (G8, brains/DESIGN-cmux-lawrence.md); nil means no machine is
/// placed (an older backend leaves the key out, which reads the same).
nonisolated struct CloudChief: Sendable, Equatable {
    nonisolated struct BrainPlace: Sendable, Equatable {
        var host: String
        var install: String
    }

    var id: String
    var displayName: String
    var isDefault: Bool
    var mainConversation: String?
    var rev: Int
    var brainPlace: BrainPlace?

    /// One `HomeChief` value; nil when a required field is missing.
    static func parse(_ value: Any?) -> CloudChief? {
        guard let value = value as? [String: Any], let id = value["id"] as? String,
              let rev = (value["rev"] as? NSNumber)?.intValue else { return nil }
        var place: BrainPlace?
        if let raw = value["brain_place"] as? [String: Any], let host = raw["host"] as? String, let install = raw["install"] as? String {
            place = BrainPlace(host: host, install: install)
        }
        return CloudChief(id: id, displayName: value["display_name"] as? String ?? "", isDefault: value["is_default"] as? Bool ?? false,
                          mainConversation: value["main_conversation"] as? String, rev: rev, brainPlace: place)
    }
}

/// The user's chiefs through the API Worker as the signed-in user: list
/// them, find the one a server answers as, and place a chief on a server
/// that was just paired. Only the user's session may place a chief (the
/// Worker refuses an install token), so this runs in the app, never on the
/// server.
@MainActor
enum CloudChiefs {
    /// One POST to the API Worker as the signed-in user (`v1/read`, `v1/ops`).
    typealias Call = @MainActor (_ path: String, _ body: [String: Any]) async throws -> [String: Any]

    /// The active chiefs of a `chief.list` value (archived ones are never listed by default).
    nonisolated static func parseList(_ value: Any?) -> [CloudChief] {
        guard let value = value as? [String: Any], let chiefs = value["chiefs"] as? [Any] else { return [] }
        return chiefs.compactMap(CloudChief.parse)
    }

    /// The chief whose brain runs on a server: the default one when it is
    /// placed, else the first placed one; nil when no chief is placed.
    nonisolated static func placed(in chiefs: [CloudChief]) -> CloudChief? {
        let placed = chiefs.filter { $0.brainPlace != nil }
        return placed.first(where: \.isDefault) ?? placed.first
    }

    static func list(call: Call) async throws -> [CloudChief] {
        parseList(try CloudPairingSource.okValue(try await call("v1/read", ["op": "chief.list", "params": [String: Any]()])))
    }

    /// Places the user's default chief on `place` (a server paired a moment
    /// ago): `chief.update {brain_place}` on the default chief, or
    /// `chief.create` when the user has none. Keys derive from `key` (the
    /// approve intent's), so a retry replays instead of writing twice. One
    /// revision conflict (another device edited the chief) re-reads once.
    static func place(_ place: CloudChief.BrainPlace, key: String, call: Call) async throws -> CloudChief {
        for attempt in 0..<2 {
            let chiefs = try await list(call: call)
            let target = chiefs.first(where: \.isDefault) ?? chiefs.first
            if let target, target.brainPlace == place { return target }
            let placeParams: [String: Any] = ["host": place.host, "install": place.install]
            let body: [String: Any]
            if let target {
                body = ["op": "chief.update", "origin": "user", "idempotency_key": "\(key)-chief-place-\(target.rev)",
                        "params": ["chief": target.id, "expected_rev": target.rev, "brain_place": placeParams]]
            } else {
                body = ["op": "chief.create", "origin": "user", "idempotency_key": "\(key)-chief-create",
                        "params": ["display_name": HomeStrings.chiefName, "is_default": true, "brain_place": placeParams]]
            }
            do {
                guard let chief = CloudChief.parse(try CloudPairingSource.okValue(try await call("v1/ops", body))) else {
                    throw FeedServiceError.badReply
                }
                // An older backend ignores brain_place: say so instead of a silent success.
                guard chief.brainPlace == place else { throw FeedServiceError.owner(code: "unsupported", message: "this cmux backend cannot place a chief on a server yet") }
                return chief
            } catch FeedServiceError.owner(code: "revision.conflict", message: _) where attempt == 0 {
                continue
            }
        }
        throw FeedServiceError.owner(code: "revision.conflict", message: "the chief changed on another device; try again")
    }
}

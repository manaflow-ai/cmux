import CmuxNextCloud
import CmuxNextHomeEngine
import CmuxNextHostedChief
import Foundation

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

    static func list(call: Call) async throws -> [CloudChief] {
        parseList(try CloudPairingSource.okValue(try await call("v1/read", ["op": "chief.list", "params": [String: Any]()])))
    }

    /// Places the user's Chief on `place` (a server paired a moment ago):
    /// `chief.update {brain_place}` on the chief already placed on a server,
    /// else `chief.create` of a placed "Chief (Mac mini)" next to the user's
    /// chiefs (a chief with no place is the Hosted Chief and stays hosted), or
    /// the default Chief when the user has none. Keys derive from `key` (the
    /// approve intent's), so a retry replays instead of writing twice. One
    /// revision conflict (another device edited the chief) re-reads once.
    static func place(_ place: CloudChief.BrainPlace, key: String, call: Call) async throws -> CloudChief {
        for attempt in 0..<2 {
            let chiefs = try await list(call: call)
            let target = HomeCloudChiefs.placed(in: chiefs)
            if let target, target.brainPlace == place { return target }
            let placeParams: [String: Any] = ["host": place.host, "install": place.install]
            let body: [String: Any]
            if let target {
                body = ["op": "chief.update", "origin": "user", "idempotency_key": "\(key)-chief-place-\(target.rev)",
                        "params": ["chief": target.id, "expected_rev": target.rev, "brain_place": placeParams]]
            } else if chiefs.isEmpty {
                body = ["op": "chief.create", "origin": "user", "idempotency_key": "\(key)-chief-create",
                        "params": ["display_name": HomeStrings.chiefName, "is_default": true, "brain_place": placeParams]]
            } else {
                body = ["op": "chief.create", "origin": "user", "idempotency_key": "\(key)-chief-create-placed",
                        "params": ["display_name": HomeCloudChiefs.placedName, "is_default": false, "brain_place": placeParams]]
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

import CmuxNextMobile
import Foundation

/// The paired phones' own acpmux credentials (`_acpmux/pair_issue` role `phone`, the person
/// only), as ``MobileHostApproverSync`` keeps them on its proven connection: hostd's channel for
/// a phone presents its credential, so the phone's Full-access setting (Settings > Devices, on
/// by default for a phone) can cover it.
///
/// The state machine is Rust's (`cmux-mobile-host-core` `credentials`, the app FFI's
/// `mobile_host` op `credentials`): only the phones the account lists get one, each new
/// connection lists acpmux's phone records first, a phone that leaves has its record end before
/// any new credential under its name, and a refusal is retried on a new connection. This keeps
/// Rust's state as JSON between events and hands back the requests to send. Credentials live in
/// memory only.
struct MobileHostPhoneCredentials {
    /// One request for the connection, as Rust names it.
    struct Request {
        enum Kind: Equatable {
            case list
            case issue(phone: String)
            case revoke(record: String)
        }
        var id: Int
        var kind: Kind
        var method: String
        var params: [String: Any]
    }

    /// Rust's whole state; nil until the first event (a fresh one).
    private var state: [String: Any]?
    /// Record names (`phone-<id>`) whose live records must end before any new credential under them.
    private(set) var ending: Set<String> = []
    /// Each phone's credential by phone device id, as hostd gets them.
    private(set) var tokens: [String: String] = [:]
    /// acpmux refused a request: a new connection retries it.
    private(set) var refused = false
    /// Whether the sync must keep (or open) its connection for these credentials.
    private(set) var needsConnection = false

    /// The paired phones (link ids) and, once the account's list is read, those it lists.
    mutating func update(paired: Set<String>, listed: Set<String>?, ids: inout Int) -> [Request] {
        var event: [String: Any] = ["kind": "update", "paired": paired.sorted()]
        if let listed { event["listed"] = listed.sorted() }
        return send(event, ids: &ids) ?? []
    }

    /// A new proven connection (the daemon may have restarted): the records are listed, then
    /// every phone gets a new credential.
    mutating func connected(ids: inout Int) -> [Request] {
        send(["kind": "connected"], ids: &ids) ?? []
    }

    /// The connection ended: open requests end with it.
    mutating func disconnected() {
        var ids = 0
        _ = send(["kind": "disconnected"], ids: &ids)
    }

    /// The reply to request `id`; nil when it is not one of these requests.
    mutating func reply(id: Int, _ message: [String: Any], ids: inout Int) -> [Request]? {
        send(["kind": "reply", "id": id, "message": message], ids: &ids)
    }

    /// One event through Rust; nil when the reply names no requests (not one of these, or no answer).
    private mutating func send(_ event: [String: Any], ids: inout Int) -> [Request]? {
        var fields: [String: Any] = ["ids": ids, "event": event]
        if let state { fields["state"] = state }
        guard let reply = MobileHostRules.ask("credentials", fields), let next = reply["state"] as? [String: Any] else { return nil }
        state = next
        if let nextIDs = reply["ids"] as? Int { ids = nextIDs }
        tokens = reply["tokens"] as? [String: String] ?? [:]
        ending = Set(reply["ending"] as? [String] ?? [])
        refused = reply["refused"] as? Bool ?? false
        needsConnection = reply["needsConnection"] as? Bool ?? false
        return (reply["requests"] as? [[String: Any]])?.compactMap(Self.request)
    }

    private static func request(_ object: [String: Any]) -> Request? {
        guard let id = object["id"] as? Int, let method = object["method"] as? String else { return nil }
        let kind: Request.Kind
        switch object["kind"] as? String {
        case "list": kind = .list
        case "issue": kind = .issue(phone: object["phone"] as? String ?? "")
        case "revoke": kind = .revoke(record: object["record"] as? String ?? "")
        default: return nil
        }
        return Request(id: id, kind: kind, method: method, params: object["params"] as? [String: Any] ?? [:])
    }
}

import CmuxNextMobile
import Foundation

/// The paired phones' own acpmux credentials (`_acpmux/pair_issue` role `phone`, the person
/// only), as ``MobileHostApproverSync`` keeps them on its proven connection: hostd's channel for
/// a phone presents its credential, so the phone's Full-access setting (Settings > Devices, off
/// by default) can cover it.
///
/// - Only ``phones`` get one: the paired phones the account still lists, so a phone with no row
///   in Settings > Devices never holds Full access.
/// - Credentials live in memory only and each new connection issues them again.
/// - A phone that leaves ``phones`` has its record revoked, and the revocation stays pending
///   (and asks for a connection) until acpmux confirms it, across lost connections.
/// - Each new connection lists acpmux's phone records once (`_acpmux/pair_list`) and revokes
///   every live one no phone in ``phones`` owns (a phone removed while the app was not running).
///   The first list is owed even when nothing else needs the connection.
struct MobileHostPhoneCredentials {
    /// One request for the connection.
    struct Request: Equatable {
        enum Kind: Equatable {
            case list
            case issue(phone: String)
            case revoke(record: String)
        }
        var id: Int
        var kind: Kind

        var method: String {
            switch kind {
            case .list: "_acpmux/pair_list"
            case .issue: "_acpmux/pair_issue"
            case .revoke: "_acpmux/pair_revoke"
            }
        }

        var params: [String: Any] {
            switch kind {
            case .list: [:]
            case .issue(let phone): ["name": MobileHostPairedDevices.acpmuxRecordName(phone), "role": "phone"]
            case .revoke(let record): ["id": record]
            }
        }
    }

    /// The phones that get a credential (link ids, from ``MobileHostPairedDevices/listed(in:)``).
    private(set) var phones: Set<String> = []
    /// Each phone's credential by phone device id, as hostd gets them.
    var tokens: [String: String] { issued.mapValues(\.token) }
    private var issued: [String: (record: String, token: String)] = [:]
    /// Records revoked here that acpmux has not confirmed yet.
    private(set) var pendingRevokes: Set<String> = []
    private var listOwed = true
    private var connected = false
    private var issuing: [Int: String] = [:]
    private var revoking: [Int: String] = [:]
    private var listing: Int?

    /// Whether the sync must keep (or open) its connection for these credentials.
    var needsConnection: Bool { !phones.isEmpty || !issued.isEmpty || !pendingRevokes.isEmpty || listOwed }

    /// A new proven connection (the daemon may have restarted): every phone gets a new credential,
    /// pending revocations go again, and the records are listed.
    mutating func connected(ids: inout Int) -> [Request] {
        connected = true
        issued = [:]
        issuing = [:]
        revoking = [:]
        ids += 1
        listing = ids
        var requests = [Request(id: ids, kind: .list)]
        for record in pendingRevokes.sorted() { requests.append(revokeRequest(record, ids: &ids)) }
        return requests + issueMissing(ids: &ids)
    }

    /// The connection ended: open requests end with it; pending revocations stay.
    mutating func disconnected() {
        connected = false
        issuing = [:]
        revoking = [:]
        listing = nil
    }

    /// The phones that should hold a credential now. A phone that left has its record revoked.
    mutating func setPhones(_ phones: Set<String>, ids: inout Int) -> [Request] {
        self.phones = phones
        var requests: [Request] = []
        for phone in issued.keys.sorted() where !phones.contains(phone) {
            if let record = issued.removeValue(forKey: phone)?.record { requests += revoke(record, ids: &ids) }
        }
        return requests + issueMissing(ids: &ids)
    }

    /// The reply to request `id`; nil when it is not one of these requests.
    mutating func reply(id: Int, _ message: [String: Any], ids: inout Int) -> [Request]? {
        let result = message["result"] as? [String: Any]
        if let phone = issuing.removeValue(forKey: id) {
            guard let result, let record = result["deviceId"] as? String, let token = result["token"] as? String else { return [] }
            // Removed while it was issued: it never reaches hostd.
            guard phones.contains(phone) else { return revoke(record, ids: &ids) }
            issued[phone] = (record, token)
            return []
        }
        if let record = revoking.removeValue(forKey: id) {
            let reason = ((message["error"] as? [String: Any])?["data"] as? [String: Any])?["reason"] as? String
            // Already gone counts as revoked; any other refusal goes again on the next connection.
            if result != nil || reason == "not_found" { pendingRevokes.remove(record) }
            return []
        }
        guard id == listing else { return nil }
        listing = nil
        guard let result else { return [] }
        listOwed = false
        let owned = Set(phones.map(MobileHostPairedDevices.acpmuxRecordName))
        let held = Set(issued.values.map(\.record))
        var requests: [Request] = []
        for device in result["devices"] as? [[String: Any]] ?? []
        where device["role"] as? String == "phone" && device["revoked_at"] is NSNull {
            guard let record = device["id"] as? String, let name = device["name"] as? String,
                  !owned.contains(name), !held.contains(record) else { continue }
            requests += revoke(record, ids: &ids)
        }
        return requests
    }

    private mutating func issueMissing(ids: inout Int) -> [Request] {
        guard connected else { return [] }
        let open = Set(issuing.values)
        return phones.sorted().filter { issued[$0] == nil && !open.contains($0) }.map { phone in
            ids += 1
            issuing[ids] = phone
            return Request(id: ids, kind: .issue(phone: phone))
        }
    }

    private mutating func revoke(_ record: String, ids: inout Int) -> [Request] {
        pendingRevokes.insert(record)
        guard connected, !revoking.values.contains(record) else { return [] }
        return [revokeRequest(record, ids: &ids)]
    }

    private mutating func revokeRequest(_ record: String, ids: inout Int) -> Request {
        ids += 1
        revoking[ids] = record
        return Request(id: ids, kind: .revoke(record: record))
    }
}

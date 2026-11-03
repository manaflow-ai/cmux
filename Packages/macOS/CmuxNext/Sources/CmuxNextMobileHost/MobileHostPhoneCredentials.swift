import CmuxNextMobile
import Foundation

/// The paired phones' own acpmux credentials (`_acpmux/pair_issue` role `phone`, the person
/// only), as ``MobileHostApproverSync`` keeps them on its proven connection: hostd's channel for
/// a phone presents its credential, so the phone's Full-access setting (Settings > Devices, off
/// by default) can cover it.
///
/// - Only ``phones`` get one: the paired phones the account lists, so a phone with no row in
///   Settings > Devices never holds Full access. Until the account's list is read, none does,
///   and no record is revoked for being unlisted (a saved setting survives the launch).
/// - Credentials live in memory only. Each new connection lists acpmux's phone records
///   (`_acpmux/pair_list`) first, revokes every live one it must, then issues the missing ones.
/// - A phone that leaves (unpaired, or no longer listed), and an unlisted record, are
///   ``ending``: the live record of that name is revoked (at once when its id is known), and no
///   credential goes under that name until a list taken after its last issue and revoke shows no
///   live record of it. So a new record never inherits a setting meant to end, and an issue whose
///   reply was lost is found by the next list.
/// - A refusal is retried on a new connection (``refused``), which the sync opens after its backoff.
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

    /// The phones that get a credential (link ids); nil until the account's list is read.
    private(set) var phones: Set<String>?
    private var paired: Set<String> = []
    /// Record names (`phone-<id>`) whose live records must end before any new credential under
    /// them: a phone that left, or an unlisted record being revoked.
    private(set) var ending: Set<String> = []
    /// Each phone's credential by phone device id, as hostd gets them.
    var tokens: [String: String] { issued.mapValues(\.token) }
    private var issued: [String: (record: String, token: String)] = [:]
    /// A list is owed on this connection.
    private var listOwed = true
    /// acpmux refused a request: a new connection retries it.
    private(set) var refused = false
    private var connected = false
    /// This connection's list has answered: issues may go.
    private var reconciled = false
    private var issuing: [Int: String] = [:]
    private var revoking: [Int: (record: String, name: String)] = [:]
    private var listing: Int?

    /// Whether the sync must keep (or open) its connection for these credentials.
    var needsConnection: Bool {
        !issued.isEmpty || !ending.isEmpty || refused || phones.map { !$0.isEmpty || listOwed } ?? false
    }

    private static func name(_ phone: String) -> String { MobileHostPairedDevices.acpmuxRecordName(phone) }

    /// The paired phones (link ids) and, once the account's list is read, those it lists. A phone
    /// that leaves either has its record end: at once when this connection holds its id, else by
    /// the next list.
    mutating func update(paired: Set<String>, listed: Set<String>?, ids: inout Int) -> [Request] {
        let wanted = listed?.intersection(paired)
        var left = self.paired.subtracting(paired)
        if let wanted, let phones { left.formUnion(phones.subtracting(wanted)) }
        if phones == nil, wanted != nil { listOwed = true }
        self.paired = paired
        phones = wanted
        let names = Set(left.map(Self.name))
        ending.formUnion(names)
        var requests: [Request] = []
        for phone in issued.keys.sorted() where wanted?.contains(phone) != true {
            guard let record = issued.removeValue(forKey: phone)?.record, ending.contains(Self.name(phone)) else { continue }
            requests += revoke(record, name: Self.name(phone), ids: &ids)
        }
        // A removal with nothing under way for it: a list finds its record, if any.
        if names.contains(where: { !busy($0) }) { listOwed = true }
        return requests + list(ids: &ids) + issueMissing(ids: &ids)
    }

    /// A new proven connection (the daemon may have restarted): the records are listed, then
    /// every phone gets a new credential.
    mutating func connected(ids: inout Int) -> [Request] {
        connected = true
        reconciled = false
        issued = [:]
        listOwed = true
        return list(ids: &ids)
    }

    /// The connection ended: open requests end with it. One whose outcome is unknown owes a list
    /// (each new connection lists anyway, but this one asks for that connection).
    mutating func disconnected() {
        if !issuing.isEmpty || !revoking.isEmpty || listing != nil { listOwed = true }
        connected = false
        reconciled = false
        issuing = [:]
        revoking = [:]
        listing = nil
    }

    /// The reply to request `id`; nil when it is not one of these requests.
    mutating func reply(id: Int, _ message: [String: Any], ids: inout Int) -> [Request]? {
        let result = message["result"] as? [String: Any]
        if let phone = issuing.removeValue(forKey: id) {
            let name = Self.name(phone)
            guard let result, let record = result["deviceId"] as? String, let token = result["token"] as? String else {
                refused = true
                return settle(name, ids: &ids)
            }
            refused = false
            if ending.contains(name) { return revoke(record, name: name, ids: &ids) }
            if phones?.contains(phone) == true { issued[phone] = (record, token) }
            return []
        }
        if let revoked = revoking.removeValue(forKey: id) {
            let reason = ((message["error"] as? [String: Any])?["data"] as? [String: Any])?["reason"] as? String
            // Already gone counts as revoked.
            refused = result == nil && reason != "not_found"
            return settle(revoked.name, ids: &ids)
        }
        guard id == listing else { return nil }
        listing = nil
        guard let result else {
            refused = true
            listOwed = true
            return []
        }
        refused = false
        reconciled = true
        let owned = Set((phones ?? []).map(Self.name)).subtracting(ending)
        let held = Set(issued.values.map(\.record))
        var live: Set<String> = []
        var requests: [Request] = []
        for device in result["devices"] as? [[String: Any]] ?? []
        where device["role"] as? String == "phone" && device["revoked_at"] is NSNull {
            guard let record = device["id"] as? String, let name = device["name"] as? String else { continue }
            live.insert(name)
            if !ending.contains(name) {
                // An unlisted record ends only once the account's list is read (a saved setting
                // survives the launch); a phone that left ends always.
                guard phones != nil, !owned.contains(name), !held.contains(record) else { continue }
                ending.insert(name)
            }
            requests += revoke(record, name: name, ids: &ids)
        }
        for name in ending where !live.contains(name) && !busy(name) {
            ending.remove(name)
        }
        return requests + list(ids: &ids) + issueMissing(ids: &ids)
    }

    private func busy(_ name: String) -> Bool {
        issuing.values.contains { Self.name($0) == name } || revoking.values.contains { $0.name == name }
    }

    /// The last open request under an ending name ended: a new list shows whether its record is gone.
    private mutating func settle(_ name: String, ids: inout Int) -> [Request] {
        guard ending.contains(name), !busy(name) else { return [] }
        listOwed = true
        return list(ids: &ids)
    }

    private mutating func list(ids: inout Int) -> [Request] {
        guard connected, listOwed, listing == nil else { return [] }
        listOwed = false
        ids += 1
        listing = ids
        return [Request(id: ids, kind: .list)]
    }

    /// Issues wait for the connection's first list and for any list in flight, and never go under
    /// an ending name, so a new record never inherits a setting that was meant to end.
    private mutating func issueMissing(ids: inout Int) -> [Request] {
        guard connected, reconciled, listing == nil, let phones else { return [] }
        let open = Set(issuing.values)
        return phones.sorted().filter { !ending.contains(Self.name($0)) && issued[$0] == nil && !open.contains($0) }.map { phone in
            ids += 1
            issuing[ids] = phone
            return Request(id: ids, kind: .issue(phone: phone))
        }
    }

    private mutating func revoke(_ record: String, name: String, ids: inout Int) -> [Request] {
        guard connected, !revoking.values.contains(where: { $0.record == record }) else { return [] }
        ids += 1
        revoking[ids] = (record, name)
        return [Request(id: ids, kind: .revoke(record: record))]
    }
}

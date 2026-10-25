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
/// - A phone that leaves (unpaired, or no longer listed) is ``removed``: its live record is
///   revoked at once when its id is known, and it gets no new credential until a list taken
///   after its last issue and revoke shows no live record of its name. So a pairing again never
///   inherits the setting, and an issue whose reply was lost is found by the next list.
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
    /// Phones whose records must end before any new credential.
    private(set) var removed: Set<String> = []
    /// Each phone's credential by phone device id, as hostd gets them.
    var tokens: [String: String] { issued.mapValues(\.token) }
    private var issued: [String: (record: String, token: String)] = [:]
    /// A list is owed on this connection.
    private var listOwed = true
    /// acpmux refused a request: a new connection retries it.
    private(set) var refused = false
    private var connected = false
    /// This connection's list has answered: issues may go (never racing its revocations).
    private var reconciled = false
    private var issuing: [Int: String] = [:]
    private var revoking: [Int: (record: String, phone: String?)] = [:]
    private var listing: Int?

    /// Whether the sync must keep (or open) its connection for these credentials.
    var needsConnection: Bool {
        !issued.isEmpty || !removed.isEmpty || refused || phones.map { !$0.isEmpty || listOwed } ?? false
    }

    /// The paired phones (link ids) and, once the account's list is read, those it lists.
    mutating func update(paired: Set<String>, listed: Set<String>?, ids: inout Int) -> [Request] {
        let wanted = listed?.intersection(paired)
        removed.formUnion(self.paired.subtracting(paired))
        if let wanted, let phones { removed.formUnion(phones.subtracting(wanted)) }
        if phones == nil, wanted != nil { listOwed = true }
        self.paired = paired
        phones = wanted
        var requests: [Request] = []
        for phone in issued.keys.sorted() where wanted?.contains(phone) != true {
            guard let record = issued.removeValue(forKey: phone)?.record, removed.contains(phone) else { continue }
            requests += revoke(record, phone: phone, ids: &ids)
        }
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
            guard let result, let record = result["deviceId"] as? String, let token = result["token"] as? String else {
                refused = true
                return settle(phone, ids: &ids)
            }
            refused = false
            if removed.contains(phone) { return revoke(record, phone: phone, ids: &ids) }
            if phones?.contains(phone) == true { issued[phone] = (record, token) }
            return []
        }
        if let revoked = revoking.removeValue(forKey: id) {
            let reason = ((message["error"] as? [String: Any])?["data"] as? [String: Any])?["reason"] as? String
            // Already gone counts as revoked.
            refused = result == nil && reason != "not_found"
            guard let phone = revoked.phone else { return [] }
            return settle(phone, ids: &ids)
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
        let owned = Set((phones ?? []).subtracting(removed).map(MobileHostPairedDevices.acpmuxRecordName))
        let held = Set(issued.values.map(\.record))
        var live: Set<String> = []
        var requests: [Request] = []
        for device in result["devices"] as? [[String: Any]] ?? []
        where device["role"] as? String == "phone" && device["revoked_at"] is NSNull {
            guard let record = device["id"] as? String, let name = device["name"] as? String else { continue }
            live.insert(name)
            let gone = removed.first { MobileHostPairedDevices.acpmuxRecordName($0) == name }
            // Unlisted records go only once the account's list is read; a removed phone's always.
            guard gone != nil || (phones != nil && !owned.contains(name) && !held.contains(record)) else { continue }
            requests += revoke(record, phone: gone, ids: &ids)
        }
        for phone in removed where !live.contains(MobileHostPairedDevices.acpmuxRecordName(phone)) && !busy(phone) {
            removed.remove(phone)
        }
        return requests + list(ids: &ids) + issueMissing(ids: &ids)
    }

    private func busy(_ phone: String) -> Bool {
        issuing.values.contains(phone) || revoking.values.contains { $0.phone == phone }
    }

    /// A removed phone's last open request ended: a new list shows whether its record is gone.
    private mutating func settle(_ phone: String, ids: inout Int) -> [Request] {
        guard removed.contains(phone), !busy(phone) else { return [] }
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

    /// Issues wait for the connection's first list and for any list in flight, so they never
    /// race the revocations a list leads to.
    private mutating func issueMissing(ids: inout Int) -> [Request] {
        guard connected, reconciled, listing == nil, let phones else { return [] }
        return phones.subtracting(removed).sorted().filter { issued[$0] == nil && !issuing.values.contains($0) }.map { phone in
            ids += 1
            issuing[ids] = phone
            return Request(id: ids, kind: .issue(phone: phone))
        }
    }

    private mutating func revoke(_ record: String, phone: String?, ids: inout Int) -> [Request] {
        guard connected, !revoking.values.contains(where: { $0.record == record }) else { return [] }
        ids += 1
        revoking[ids] = (record, phone)
        return [Request(id: ids, kind: .revoke(record: record))]
    }
}

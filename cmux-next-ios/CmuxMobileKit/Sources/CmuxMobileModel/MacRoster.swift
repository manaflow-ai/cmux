import Foundation

/// Which of the account's Macs the Mac filter, Workspaces and Home list.
///
/// Every cmux install registers its own device id, so one computer can be on
/// the account twice: an earlier build (a test app since deleted) or a
/// reinstall leaves a record that stays offline for good beside the live one
/// ("Abdulaziz's MacBook Pro (2) 3EB7" online and "… 39C6" offline). A record
/// is retired from those lists when:
/// - it is offline and another Mac with the same name and the same owner is
///   online or was seen later (the same computer's newer install; a
///   teammate's same-named Mac is another computer), or
/// - it was last seen more than `staleAfter` ago and another Mac stays listed.
///
/// Retired Macs stay in Settings → Devices, where Remove deletes them, and a
/// retired Mac that comes online is listed again.
public struct MacRoster: Equatable, Sendable {
    /// How long an offline Mac stays listed with no sign of life.
    public static let staleAfter: TimeInterval = 30 * 24 * 3600

    /// Listed, in the given order.
    public let visible: [MacDevice]
    /// Not listed, in the given order.
    public let retired: [MacDevice]

    public init(_ macs: [MacDevice], now: Date = Date()) {
        func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func replaced(_ mac: MacDevice) -> Bool {
            guard !mac.isOnline else { return false }
            let seen = mac.lastSeenAt ?? .distantPast
            return macs.contains { other in
                other.id != mac.id && key(other.name) == key(mac.name) && other.ownerUserID == mac.ownerUserID
                    && (other.isOnline || (other.lastSeenAt ?? .distantPast) > seen)
            }
        }
        var retiredIDs = Set(macs.filter(replaced).map(\.id))
        let stale = macs.filter { mac in
            guard !mac.isOnline, !retiredIDs.contains(mac.id), let seen = mac.lastSeenAt else { return false }
            return now.timeIntervalSince(seen) > Self.staleAfter
        }
        // Never empty the lists on their own: one Mac always stays.
        if macs.count - retiredIDs.count > stale.count { retiredIDs.formUnion(stale.map(\.id)) }
        visible = macs.filter { !retiredIDs.contains($0.id) }
        retired = macs.filter { retiredIDs.contains($0.id) }
    }
}

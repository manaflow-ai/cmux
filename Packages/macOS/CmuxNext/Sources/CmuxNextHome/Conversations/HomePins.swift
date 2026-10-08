public import CmuxHomeCore
import Foundation

/// Which conversations are pinned (the Home sidebar's grid). Client side,
/// per account, until the daemon's cloud proxy forwards `inbox.pin`
/// (home-cloud-proxy.md 8; the local owner refuses pins too): `pinned` is
/// the user's order; Chiefs and owner-pinned conversations are pinned by
/// default unless the user unpinned them (`unpinned`).
public struct HomePins: Hashable, Sendable, Codable {
    public var pinned: [ConversationID]
    public var unpinned: Set<ConversationID>

    public init(pinned: [ConversationID] = [], unpinned: Set<ConversationID> = []) {
        self.pinned = pinned
        self.unpinned = unpinned
    }

    public func isPinned(_ row: InboxRow) -> Bool {
        if pinned.contains(row.id) { return true }
        if unpinned.contains(row.id) { return false }
        return row.kind == .chief || row.isPinned
    }

    /// Pins `row` (at the end of the user's order) or unpins it.
    public mutating func setPinned(_ on: Bool, _ row: InboxRow) {
        pinned.removeAll { $0 == row.id }
        unpinned.remove(row.id)
        if on { pinned.append(row.id) } else if row.kind == .chief || row.isPinned { unpinned.insert(row.id) }
    }
}

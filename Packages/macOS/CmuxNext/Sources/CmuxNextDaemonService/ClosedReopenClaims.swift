import CmuxNextDaemon

/// Which closed items this app's reopens took (the app's `CloseUndoToasts.reopenClaims`): the one
/// owner of every reopen of a closed item, the undo toast's Undo, History, Reopen Closed Screen or
/// Workspace (`DaemonClosedHistory.reopen`) and each Cmd-Shift-T press
/// (`DaemonClosedHistory.reopenNewest`). A second request for an item on its way or
/// reopened is refused with a HUD message instead of being sent to fail as not found, and the next
/// Cmd-Shift-T skips the item: behind an Undo of the newest it takes the next newest, as Chrome's
/// Reopen Closed Tab does. A duplicate that still reaches the daemon (another app, the CLI) carries
/// the item's own idempotency key (`StateResourceClient.reopenKey`) and replays the first reopen.
///
/// An item is reopening from its claim to its reply. A failed reopen lets it go (the next request
/// may take it again); a reopened one stays reopened (the store drops it only on the daemon's
/// event, after the reply; a closed id is never made again, so the newest 256 are kept).
public struct ClosedReopenClaims<Send> {
    private var reopening: Set<String> = []
    private var reopened: Set<String> = []
    private var reopenedOrder: [String] = []
    /// The by-id reopens on their way (`DaemonClosedHistory.reopen`), by ticket: a Cmd-Shift-T
    /// press sends after those made before it replied, so it never picks their item.
    public private(set) var sends: [UInt64: Send] = [:]
    private var lastTicket: UInt64 = 0

    public init() {}

    public func contains(_ id: String) -> Bool { reopening.contains(id) || reopened.contains(id) }

    /// Takes item `id` for a reopen on its way.
    public mutating func claim(_ id: String) { reopening.insert(id) }

    /// Item `id`'s reopen replied: reopened, or let go for the next request.
    public mutating func settle(_ id: String, reopened done: Bool) {
        reopening.remove(id)
        guard done, reopened.insert(id).inserted else { return }
        reopenedOrder.append(id)
        if reopenedOrder.count > 256 { reopened.remove(reopenedOrder.removeFirst()) }
    }

    /// Why `item` cannot be taken now (a HUD message), or nil when it can.
    public func refusal(for item: ClosedItem) -> String? {
        if reopening.contains(item.id) { return item.kind == .tab ? RefusalStrings.closedTabReopening : RefusalStrings.closedItemReopening }
        if reopened.contains(item.id) { return item.kind == .tab ? RefusalStrings.closedTabReopened : RefusalStrings.closedItemReopened }
        return nil
    }

    /// The ticket of the next by-id reopen's send.
    public mutating func nextTicket() -> UInt64 {
        lastTicket += 1
        return lastTicket
    }

    public mutating func addSend(_ ticket: UInt64, _ send: Send) { sends[ticket] = send }

    public mutating func removeSend(_ ticket: UInt64) { sends[ticket] = nil }
}

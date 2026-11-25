/// The ended values of each layout transaction the daemon has not answered yet. The app sends every ended value as its
/// own command and settles the transaction at each reply (`WorkspaceContentController.sendGesture`), so a transaction
/// of several values (a keyboard trade's two widths, an Option or Command drag's release, a split's sizing) settles only
/// at the reply to its last one: settled earlier, a daemon snapshot taken between two of its commands' events dropped the
/// values still on their way, and for a frame the screen showed them at their old sizes.
struct TransactionReplies {
    private var unanswered: [LayoutTransactionID: Int] = [:]
    /// The changes going out now (`EndedValues.send`), innermost last: one can be sent from inside another's intent
    /// handler, even one of the same transaction. Each notes whether the app refused its transaction meanwhile.
    private var sending: [(transaction: LayoutTransactionID, refused: Bool)] = []

    /// One more value of `transaction` goes to the daemon.
    mutating func expect(_ transaction: LayoutTransactionID) { unanswered[transaction, default: 0] += 1 }

    /// A reply for `transaction` came: true when it was the last one its values wait for (or one nobody counted).
    mutating func answered(_ transaction: LayoutTransactionID) -> Bool {
        guard let left = unanswered[transaction], left > 1 else {
            unanswered[transaction] = nil
            return true
        }
        unanswered[transaction] = left - 1
        return false
    }

    /// `transaction` was refused or cancelled: no reply settles it.
    mutating func forget(_ transaction: LayoutTransactionID) {
        unanswered[transaction] = nil
        for index in sending.indices where sending[index].transaction == transaction { sending[index].refused = true }
    }

    /// A change of `transaction` starts going out: a refusal of it while it does is noted (``forget(_:)``), whatever it
    /// removed.
    mutating func beginSending(_ transaction: LayoutTransactionID) { sending.append((transaction, false)) }

    /// Whether the app refused the innermost change going out: the caller's own once its emit returned (sends nest).
    var refusedInnermost: Bool { sending.last?.refused == true }

    /// The innermost change went out (or stopped): whether the app refused its transaction meanwhile.
    mutating func endSending() -> Bool { sending.popLast()?.refused == true }
}

/// A divider or column value a gesture set locally (`LayoutModel.splitOverrides`, `widthOverrides`), shown over the
/// daemon's snapshots until the daemon answers its transaction.
struct GestureOverride {
    var value: Double
    var transaction: LayoutTransactionID
    var ended = false
    /// The daemon accepted the gesture's final command: the next snapshot
    /// is authoritative (it was requested after the command committed on
    /// the same serial connection), so the override yields to it.
    var settled = false
}

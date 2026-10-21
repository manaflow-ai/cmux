import Foundation

/// Mutable control-channel state for one pane snapshot transaction.
struct RemoteTmuxPendingPaneSeed {
    let id: UUID
    let kind: RemoteTmuxPaneSeedKind
    var discardedOutput: [Data] = []
    var snapshot: Data
    /// History rows read before the screen capture, each ending in CR LF. They are
    /// painted after the screen clear and before the screen rows.
    var historyRows = Data()
    var catchUpOutput: [Data] = []
    var bufferedLiveByteCount = 0
    var isCaptureInstalled = false

    var retainedByteCount: Int {
        snapshot.count + historyRows.count + bufferedLiveByteCount
    }
}

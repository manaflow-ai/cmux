import Foundation

/// Mutable control-channel state for one pane snapshot transaction.
struct RemoteTmuxPendingPaneSeed {
    let id: UUID
    let kind: RemoteTmuxPaneSeedKind
    var discardedOutput: [Data] = []
    var snapshot: Data
    /// History rows read before the screen capture, oldest first, one entry per row
    /// and each ending in CR LF. They are painted after the screen clear and before
    /// the screen rows.
    var historyRows: [Data] = []
    var historyByteCount = 0
    /// History rows dropped from the oldest end to stay within the byte budget.
    var droppedHistoryRows = 0
    /// History rows moved into `snapshot` when the screen capture was installed.
    var paintedHistoryRows = 0
    var catchUpOutput: [Data] = []
    var bufferedLiveByteCount = 0
    var isCaptureInstalled = false

    var retainedByteCount: Int {
        snapshot.count + historyByteCount + bufferedLiveByteCount
    }
}

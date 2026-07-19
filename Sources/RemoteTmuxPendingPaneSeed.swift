import Foundation

/// Mutable control-channel state for one pane snapshot transaction.
struct RemoteTmuxPendingPaneSeed {
    let id: UUID
    var discardedOutput: [Data] = []
    var snapshot: Data
    var catchUpOutput: [Data] = []
    var bufferedLiveByteCount = 0
    var isCaptureInstalled = false
}

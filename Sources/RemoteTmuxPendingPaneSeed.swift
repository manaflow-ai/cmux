import Foundation

/// Mutable control-channel state for one pane snapshot transaction.
struct RemoteTmuxPendingPaneSeed {
    let id: UUID
    let kind: RemoteTmuxPaneSeedKind
    var discardedOutput: [Data] = []
    var snapshot: Data
    var catchUpOutput: [Data] = []
    var bufferedLiveByteCount = 0
    var isCaptureInstalled = false
    /// Live output before the capture result is dropped instead of retained.
    /// Set by a catch-up after the stream fell behind: that output is stale, the
    /// capture covers it, and retaining it would only run into the live-byte
    /// budget and restart the seed.
    var dropsPreCaptureOutput = false

    var retainedByteCount: Int {
        snapshot.count + bufferedLiveByteCount
    }
}

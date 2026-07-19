import Foundation

/// Mutable control-channel state for one pane snapshot transaction.
struct RemoteTmuxPendingPaneSeed {
    enum Phase: Equatable {
        case awaitingCapture
        case captured
    }

    let id: UUID
    var discardedOutput: [Data] = []
    var snapshot: Data
    var catchUpOutput: [Data] = []
    var bufferedLiveByteCount = 0
    var phase: Phase = .awaitingCapture
}

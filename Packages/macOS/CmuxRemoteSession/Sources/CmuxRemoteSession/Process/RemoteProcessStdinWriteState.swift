internal import CmuxFoundation

/// Lock-free publication of the stdin writer's terminal error.
///
/// The writer stores one immutable error before release-publishing the gate.
/// The blocking owner uses an acquire load before reading that value.
final class RemoteProcessStdinWriteState: @unchecked Sendable {
    private let hasRecordedError = AtomicBooleanGate(false)
    nonisolated(unsafe) private var error: (any Error)?

    func record(error: any Error) {
        self.error = error
        hasRecordedError.storeRelease(true)
    }

    var recordedError: (any Error)? {
        guard hasRecordedError.loadAcquire() else { return nil }
        return error
    }
}

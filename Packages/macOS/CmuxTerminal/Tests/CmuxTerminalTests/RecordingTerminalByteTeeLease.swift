@testable import CmuxTerminal

/// A byte-tee lease that reports its release to a ``TeardownOrderRecorder``
/// so lifetime tests can assert release ordering against the native free.
final class RecordingTerminalByteTeeLease: TerminalByteTeeLease {
    private let recorder: TeardownOrderRecorder

    init(recorder: TeardownOrderRecorder) {
        self.recorder = recorder
    }

    func release() {
        recorder.record(.teeLeaseRelease)
    }
}

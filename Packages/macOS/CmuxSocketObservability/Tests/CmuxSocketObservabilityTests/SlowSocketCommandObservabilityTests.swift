import Foundation
import Testing
@testable import CmuxSocketObservability

/// Recording sink for structural reporter assertions.
///
/// Safety: mutable records are protected by `lock`.
private final class RecordingSlowSocketCommandSink: SlowSocketCommandSink, @unchecked Sendable {
    // Protects records captured from a Sendable sink during synchronous tests.
    private let lock = NSLock()
    private var _records: [SocketCommandObservation] = []

    var records: [SocketCommandObservation] {
        lock.lock()
        defer { lock.unlock() }
        return _records
    }

    func recordSlowCommand(_ observation: SocketCommandObservation) {
        lock.lock()
        _records.append(observation)
        lock.unlock()
    }
}

@Suite
struct SlowSocketCommandObservabilityTests {
    private func observation(durationMs: Double) -> SocketCommandObservation {
        SocketCommandObservation(
            protocolName: "v2",
            method: "browser.eval",
            durationMs: durationMs,
            executedOnMain: true,
            peerPid: 4242,
            responseByteCount: 12
        )
    }

    @Test
    func testFastCommandIsNotReported() {
        let sink = RecordingSlowSocketCommandSink()
        let reporter = SlowSocketCommandReporter(sink: sink)
        reporter.reportIfSlow(observation(durationMs: 1))
        reporter.reportIfSlow(observation(durationMs: 99.9))
        #expect(sink.records.isEmpty)
    }

    @Test
    func testSlowCommandIsReportedWithFieldsPreserved() {
        let sink = RecordingSlowSocketCommandSink()
        let reporter = SlowSocketCommandReporter(sink: sink)
        reporter.reportIfSlow(observation(durationMs: 150))
        #expect(sink.records.count == 1)
        let record = sink.records[0]
        #expect(record.method == "browser.eval")
        #expect(record.protocolName == "v2")
        #expect(record.executedOnMain)
        #expect(record.peerPid == 4242)
        #expect(record.responseByteCount == 12)
        #expect(record.durationMs == 150)
    }

    @Test
    func testSlowThresholdBoundaryIsInclusiveAt100ms() {
        #expect(!SlowSocketCommandReporter.isSlow(durationMs: 99.999))
        #expect(SlowSocketCommandReporter.isSlow(durationMs: 100))
        #expect(SlowSocketCommandReporter.isSlow(durationMs: 100.001))
    }

}

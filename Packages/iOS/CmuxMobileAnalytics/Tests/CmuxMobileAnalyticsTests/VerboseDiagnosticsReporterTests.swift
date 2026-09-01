import CMUXMobileCore
import Foundation
import Testing
import os

@testable import CmuxMobileAnalytics

/// Records every batch the reporter attempts and returns a scripted result,
/// so tests can assert exact upload contents and drive failure paths.
private final class RecordingVerboseDiagnosticsUploader:
    VerboseDiagnosticsUploading, Sendable {
    private let state = OSAllocatedUnfairLock(
        initialState: (
            batches: [VerboseDiagnosticsBatch](),
            result: AnalyticsUploadResult.accepted
        )
    )

    var batches: [VerboseDiagnosticsBatch] {
        state.withLock { $0.batches }
    }

    var uploadCount: Int {
        state.withLock { $0.batches.count }
    }

    func setResult(_ result: AnalyticsUploadResult) {
        state.withLock { $0.result = result }
    }

    func upload(_ batch: VerboseDiagnosticsBatch) async -> AnalyticsUploadResult {
        state.withLock { state in
            state.batches.append(batch)
            return state.result
        }
    }
}

@Suite("VerboseDiagnosticsReporter")
struct VerboseDiagnosticsReporterTests {
    /// Anchor pair mapping monotonic nano 500 to wall second 1_000_000_000.
    private static let anchorWallNanos: UInt64 = 1_000_000_000_000_000_000
    private static let anchorMonotonicNanos: UInt64 = 500

    private func makeReporter(
        uploader: RecordingVerboseDiagnosticsUploader,
        flushBatchSize: Int = 40,
        maxPendingEvents: Int = 512
    ) -> VerboseDiagnosticsReporter {
        VerboseDiagnosticsReporter(
            uploader: uploader,
            buildStamp: "cmux 1.0 (42)",
            clientID: "install-1",
            flushBatchSize: flushBatchSize,
            // A cadence long enough that only explicit flush() and the
            // batch-size drain can trigger uploads within the test.
            flushInterval: .seconds(3600),
            maxPendingEvents: maxPendingEvents,
            anchorWallNanos: Self.anchorWallNanos,
            anchorMonotonicNanos: Self.anchorMonotonicNanos
        )
    }

    @Test("Unauthorized accounts upload nothing")
    func unauthorizedUploadsNothing() async {
        let uploader = RecordingVerboseDiagnosticsUploader()
        let reporter = makeReporter(uploader: uploader)

        reporter.ingest(DiagnosticEvent(code: .connect, tNanos: 1_500))
        reporter.ingest(DiagnosticEvent(code: .pairOk, tNanos: 2_500))
        await reporter.flush()

        #expect(uploader.uploadCount == 0)
    }

    @Test("Authorized events batch with resolved timestamps and text")
    func authorizedEventsBatchWithResolvedFields() async throws {
        let uploader = RecordingVerboseDiagnosticsUploader()
        let reporter = makeReporter(uploader: uploader)

        reporter.setAuthorization(enabled: true)
        reporter.ingest(DiagnosticEvent(code: .connect, tNanos: 500))
        reporter.ingest(DiagnosticEvent(
            code: .transportDialFailed,
            tNanos: 2_000_000_500,
            ms: 250,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.timedOut.rawValue
        ))
        await reporter.flush()

        #expect(uploader.uploadCount == 1)
        let batch = try #require(uploader.batches.first)
        #expect(batch.buildStamp == "cmux 1.0 (42)")
        #expect(batch.clientID == "install-1")
        try #require(batch.entries.count == 2)

        let first = batch.entries[0]
        #expect(first.code == Int(DiagnosticEventCode.connect.rawValue))
        #expect(first.name == "connect")
        // The anchor pair maps monotonic 500 to exactly the wall anchor.
        #expect(first.at == Date(timeIntervalSince1970: 1_000_000_000))

        let second = batch.entries[1]
        #expect(second.name == "transportDialFailed")
        #expect(second.ms == 250)
        #expect(!second.summary.isEmpty)
        // Two seconds after the anchor.
        #expect(second.at == Date(timeIntervalSince1970: 1_000_000_002))
    }

    @Test("Reaching the batch size drains without an explicit flush")
    func batchSizeDrains() async {
        let uploader = RecordingVerboseDiagnosticsUploader()
        let reporter = makeReporter(uploader: uploader, flushBatchSize: 3)

        reporter.setAuthorization(enabled: true)
        for index in 0..<3 {
            reporter.ingest(DiagnosticEvent(code: .connect, tNanos: UInt64(1_000 + index)))
        }
        // The barrier orders this assertion point after the batch-size drain.
        await reporter.flush()

        #expect(uploader.uploadCount == 1)
        #expect(uploader.batches.first?.entries.count == 3)
    }

    @Test("A failed upload is dropped, never retried, and opens the outage gate")
    func failureDropsBatchAndSuppressesPerEventDrains() async throws {
        let uploader = RecordingVerboseDiagnosticsUploader()
        let reporter = makeReporter(uploader: uploader, flushBatchSize: 2)

        reporter.setAuthorization(enabled: true)
        uploader.setResult(.retry)
        reporter.ingest(DiagnosticEvent(code: .connect, tNanos: 1_000))
        reporter.ingest(DiagnosticEvent(code: .pairOk, tNanos: 2_000))
        await reporter.flush()
        let attemptsAfterFailure = uploader.uploadCount
        #expect(attemptsAfterFailure >= 1)

        // While the outage gate is open, batch-size drains are suppressed:
        // these events buffer without triggering another POST.
        reporter.ingest(DiagnosticEvent(code: .connect, tNanos: 3_000_000_000))
        reporter.ingest(DiagnosticEvent(code: .pairOk, tNanos: 4_000_000_000))
        reporter.ingest(DiagnosticEvent(code: .connect, tNanos: 5_000_000_000))

        // The next explicit drain ships only the FRESH events; the failed
        // batch is gone.
        uploader.setResult(.accepted)
        await reporter.flush()

        #expect(uploader.uploadCount == attemptsAfterFailure + 1)
        let lastBatch = try #require(uploader.batches.last)
        #expect(lastBatch.entries.count == 3)
        // All shipped events postdate the dropped ones (wall mapping of the
        // 3s+ monotonic stamps).
        #expect(lastBatch.entries.allSatisfy { entry in
            entry.at > Date(timeIntervalSince1970: 1_000_000_001)
        })

        // A rejected upload (server double gate, 4xx) behaves the same: the
        // batch is dropped, nothing is requeued.
        uploader.setResult(.drop)
        reporter.ingest(DiagnosticEvent(code: .connect, tNanos: 6_000_000_000))
        await reporter.flush()
        let afterRejection = uploader.uploadCount
        uploader.setResult(.accepted)
        await reporter.flush()
        #expect(uploader.uploadCount == afterRejection)
    }

    @Test("Revoking authorization discards buffered events")
    func revokingAuthorizationDropsPending() async {
        let uploader = RecordingVerboseDiagnosticsUploader()
        let reporter = makeReporter(uploader: uploader)

        reporter.setAuthorization(enabled: true)
        reporter.ingest(DiagnosticEvent(code: .connect, tNanos: 1_000))
        reporter.setAuthorization(enabled: false)
        await reporter.flush()

        #expect(uploader.uploadCount == 0)
    }

    @Test("The backlog is hard-capped during an outage, dropping oldest")
    func backlogIsBounded() async throws {
        let uploader = RecordingVerboseDiagnosticsUploader()
        let reporter = makeReporter(
            uploader: uploader,
            flushBatchSize: 2,
            maxPendingEvents: 4
        )

        // Open the outage gate so per-event drains stop and events buffer.
        reporter.setAuthorization(enabled: true)
        uploader.setResult(.retry)
        reporter.ingest(DiagnosticEvent(code: .connect, tNanos: 1_000))
        reporter.ingest(DiagnosticEvent(code: .pairOk, tNanos: 2_000))
        await reporter.flush()
        let attemptsAfterFailure = uploader.uploadCount

        // Ten events into a cap of four: only the newest four survive.
        for index in 0..<10 {
            reporter.ingest(DiagnosticEvent(
                code: .connect,
                tNanos: UInt64(10_000_000_000 + index)
            ))
        }
        uploader.setResult(.accepted)
        await reporter.flush()

        #expect(uploader.uploadCount == attemptsAfterFailure + 1)
        let lastBatch = try #require(uploader.batches.last)
        #expect(lastBatch.entries.count == 4)
    }
}

import CmuxNextCompat
@testable import CmuxNextHangReports
import CmuxNextInputCore
import Foundation
import Testing

/// The service and the input latency field report: sent only in schema 3,
/// recorded only while reports are on, previewed without a take, taken once per send and
/// committed only once queued, and trimmed before hangs when a report is over the body cap.
/// Run: `swift test --filter HangReportServiceTests`.
extension HangReportServiceTests {
    /// A field report that holds what the test records, like `InputLatencyReporter`'s: off drops
    /// it, a take holds it until commit.
    final class FakeInputLatencySource: HangReportInputLatencySource {
        struct State {
            var recording = false
            var pending: InputLatencySnapshot?
            var recordings: [Bool] = []
            var previews = 0
            var takes = 0
            var commits = 0
        }

        let state = Mutex(State())

        func record(_ snapshot: InputLatencySnapshot) {
            state.withLock { if $0.recording { $0.pending = snapshot } }
        }

        func setRecording(_ on: Bool) async {
            state.withLock {
                $0.recordings.append(on)
                $0.recording = on
                if !on { $0.pending = nil }
            }
        }

        func preview() async -> InputLatencySnapshot? {
            state.withLock {
                $0.previews += 1
                return $0.recording ? $0.pending : nil
            }
        }

        func take() async -> InputLatencySnapshot? {
            state.withLock {
                $0.takes += 1
                return $0.recording ? $0.pending : nil
            }
        }

        func commit() async {
            state.withLock {
                $0.commits += 1
                $0.pending = nil
            }
        }

        var current: State { state.withLock { $0 } }
    }

    @Test func aSchemaThreeSendCarriesTheInputLatencyTakenOnceAndCommitted() async throws {
        let source = FakeInputLatencySource()
        let transport = RecordingTransport()
        let service = service(transport, wireSchema: .v3, inputLatency: source)
        await service.setEnabled(true)
        source.record(InputLatencyReportTests.fieldSnapshot())
        await service.receive(HangReportFixtures.metricKitInput())
        let text = String(decoding: try #require(transport.sent.first), as: UTF8.self)
        for key in ["\"input_latency_bucket_edges_ms\"", "\"input_latency\"", "\"scroll_jank\"", "\"display\""] {
            #expect(text.contains(key), "missing \(key)")
        }
        #expect(source.current.takes == 1, "a take per send, not a peek")
        #expect(source.current.commits == 1, "committed once queued")
        #expect(source.current.pending == nil)
    }

    @Test func aSchemaTwoServiceNeverRecordsInputLatency() async throws {
        let source = FakeInputLatencySource()
        let transport = RecordingTransport()
        let service = service(transport, wireSchema: .v2, inputLatency: source)
        await service.setEnabled(true)
        await service.receive(HangReportFixtures.metricKitInput())
        #expect(source.current.recordings.isEmpty)
        #expect(source.current.takes == 0)
        #expect(!String(decoding: try #require(transport.sent.first), as: UTF8.self).contains("input_latency"))
    }

    @Test func inputRecordedBeforeReportsWereTurnedOffIsNeverSent() async throws {
        let source = FakeInputLatencySource()
        let transport = RecordingTransport()
        let service = service(transport, wireSchema: .v3, inputLatency: source)
        await service.setEnabled(true)
        source.record(InputLatencyReportTests.fieldSnapshot())
        await service.setEnabled(false)
        await service.setEnabled(true)
        await service.receive(HangReportFixtures.metricKitInput())
        #expect(source.current.recordings == [true, false, true])
        let sent = try JSONDecoder().decode(HangReport.self, from: #require(transport.sent.first))
        #expect(sent.inputLatency == nil && sent.scrollJank == nil)
    }

    @Test func aManagedBlockStopsTheFieldReport() async {
        let allowed = Mutex(true)
        let source = FakeInputLatencySource()
        let service = service(RecordingTransport(), allowed: { allowed.withLock { $0 } }, wireSchema: .v3, inputLatency: source)
        await service.setEnabled(true)
        source.record(InputLatencyReportTests.fieldSnapshot())
        allowed.withLock { $0 = false }
        await service.receive(HangReportFixtures.metricKitInput())
        #expect(source.current.recordings == [true, false])
        #expect(source.current.pending == nil)
    }

    @Test func thePreviewHoldsTheInputKeysWithoutTakingThem() async throws {
        let source = FakeInputLatencySource()
        let transport = RecordingTransport()
        let service = service(transport, wireSchema: .v3, inputLatency: source)
        await service.setEnabled(true)
        source.record(InputLatencyReportTests.fieldSnapshot())
        let url = try #require(await service.viewableReport())
        let preview = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(preview.contains("\"input_latency\"") && preview.contains("\"scroll_jank\""))
        #expect(source.current.previews == 1)
        #expect(source.current.takes == 0)
        #expect(source.current.pending != nil, "the preview took nothing")
        #expect(transport.sent.isEmpty)
    }

    /// 64 input rows, the most frequent first, on four displays.
    static func inputRows() -> [HangReport.InputLatencyRow] {
        let kinds = ["keyPress", "mousePress", "scrollUpdate", "pointerMove"]
        let targets = ["terminal", "sidebar", "layout", "chromiumPage"]
        let displays = [HangReport.Display(refreshHz: 60, vrr: false), HangReport.Display(refreshHz: 120, vrr: true),
                        HangReport.Display(refreshHz: 144, vrr: false), HangReport.Display(refreshHz: 90, vrr: true)]
        var rows: [HangReport.InputLatencyRow] = []
        for kind in kinds {
            for target in targets {
                for display in displays {
                    let index = rows.count
                    var buckets = [UInt64](repeating: 0, count: InputLatencyBuckets.bucketCount)
                    buckets[index % buckets.count] = UInt64(1_000 - index)
                    rows.append(HangReport.InputLatencyRow(kind: kind, target: target, entrypoint: "person",
                                                           presentationSource: "estimatedVsync", display: display,
                                                           count: UInt64(1_000 - index), buckets: buckets, maxMs: 12.5))
                }
            }
        }
        return rows
    }

    static func deepHang(_ durationMs: Int) -> HangSample {
        HangSample(source: .watchdog, kind: .stall, durationMs: durationMs,
                   frames: (0..<HangSample.maxFrames).map {
                       HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: UInt64(100_000 + $0))
                   })
    }

    static func size(_ report: HangReport) throws -> Int {
        try HangReport.encoder.encode(report).count
    }

    @Test func anOverCapReportDropsInputLatencyBeforeAnyHang() throws {
        var report = InputLatencyReportTests.report(InputLatencyReportTests.fieldSnapshot())
        report.inputLatency = Self.inputRows()
        let inputBytes = try Self.size(report)
        // Hangs that fit alone with room to spare, but not with the input rows.
        var hangs: [HangSample] = []
        while true {
            var probe = report
            probe.inputLatency = nil
            probe.scrollJank = nil
            probe.inputLatencyBucketEdgesMs = nil
            probe.hangs = hangs + [Self.deepHang(5_000 - hangs.count)]
            guard try Self.size(probe) <= HangReport.maxBodyBytes - inputBytes / 2 else { break }
            hangs = probe.hangs
        }
        report.hangs = hangs
        try #require(try Self.size(report) > HangReport.maxBodyBytes)
        let fitted = HangReportService.fitted(report)
        #expect(try Self.size(fitted) <= HangReport.maxBodyBytes)
        #expect(fitted.hangs == hangs, "every hang stays")
        let rows = try #require(fitted.inputLatency)
        #expect(!rows.isEmpty && rows.count < 64)
        #expect(rows == Array(Self.inputRows().prefix(rows.count)), "the least frequent rows went, the rest keep their order")
    }

    @Test func hangsThatAloneExceedTheCapLeaveNoInputBlock() throws {
        var report = InputLatencyReportTests.report(InputLatencyReportTests.fieldSnapshot())
        report.inputLatency = Self.inputRows()
        report.hangs = (0..<HangReport.maxHangs).map { Self.deepHang(9_000 - $0) }
        var hangsOnly = report
        hangsOnly.inputLatency = nil
        try #require(try Self.size(hangsOnly) > HangReport.maxBodyBytes)
        let fitted = HangReportService.fitted(report)
        #expect(try Self.size(fitted) <= HangReport.maxBodyBytes)
        #expect(fitted.inputLatency == nil && fitted.scrollJank == nil && fitted.inputLatencyBucketEdgesMs == nil,
                "the three input keys go together")
        #expect(!fitted.hangs.isEmpty)
    }
}

import CMUXMobileCore
import Testing

@testable import CmuxIrohTransport

@Suite
struct CmxIrohConnectionDiagnosticRecorderTests {
    @Test
    func mapsPathEventsAndClampsApplicationErrorCode() async {
        let log = DiagnosticLog(capacity: 8)
        let recorder = CmxIrohConnectionDiagnosticRecorder(
            diagnosticLog: log,
            sessionID: 23
        )

        recorder.record(CmxIrohConnectionPathEvent(
            kind: .opened,
            pathKind: .privateNetwork
        ))
        recorder.record(CmxIrohConnectionPathEvent(
            kind: .closed,
            pathKind: .direct
        ))
        recorder.record(CmxIrohConnectionPathEvent(
            kind: .selected,
            pathKind: .relay
        ))
        recorder.record(CmxIrohConnectionPathEvent(
            kind: .lagged,
            pathKind: .unknown
        ))
        recorder.record(CmxIrohConnectionCloseAttribution(
            initiator: .remote,
            applicationErrorCode: Int64.max,
            failureKind: .connectionClosed
        ))

        for _ in 0 ..< 1_000 {
            if await log.processedCount() >= 5 { break }
            await Task.yield()
        }
        let events = await log.snapshot().events
        #expect(events.map(\.code) == [
            .transportPathEvent,
            .transportPathEvent,
            .transportPathEvent,
            .transportPathEvent,
            .transportCloseAttribution,
        ])
        #expect(events.map(\.a) == [1, 2, 3, 4, 2])
        #expect(events.map(\.b) == [
            DiagnosticPathKind.privateNetwork.rawValue,
            DiagnosticPathKind.direct.rawValue,
            DiagnosticPathKind.relay.rawValue,
            DiagnosticPathKind.unknown.rawValue,
            DiagnosticFailureKind.connectionClosed.rawValue,
        ])
        #expect(events.allSatisfy { $0.c == 23 })
        #expect(events.last?.ms == UInt32(Int32.max))
    }
}

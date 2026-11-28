import CMUXMobileCore
import IrohLib
import Testing

@testable import CmuxIrohTransport

@Suite
struct CmxIrohConnectionDiagnosticRecorderTests {
    @Test
    func mapsIrohPathEventsToRedactedKinds() {
        let events = [
            CmxIrohConnectionPathEvent(.opened(
                id: "private",
                remoteAddr: "192.168.1.10:443",
                localAddr: "192.168.1.2:5000"
            )),
            CmxIrohConnectionPathEvent(.closed(
                id: "direct",
                remoteAddr: "8.8.8.8:443",
                localAddr: "192.168.1.2:5001",
                lastStats: PathStatsRecord(
                    rttMs: 0,
                    udpTxDatagrams: 0,
                    udpTxBytes: 0,
                    udpRxDatagrams: 0,
                    udpRxBytes: 0,
                    cwnd: 0,
                    congestionEvents: 0,
                    lostPackets: 0,
                    lostBytes: 0,
                    currentMtu: 0
                )
            )),
            CmxIrohConnectionPathEvent(.selected(
                id: "relay",
                remoteAddr: "https://relay.example",
                localAddr: "https://relay.example"
            )),
            CmxIrohConnectionPathEvent(.lagged(missed: 3)),
        ]

        #expect(events.map(\.kind) == [.opened, .closed, .selected, .lagged])
        #expect(events.map(\.pathKind) == [
            .privateNetwork,
            .direct,
            .relay,
            .unknown,
        ])
    }

    @Test
    func callbackRecordsLagWhenItsBoundedBufferEvicts() async {
        let (stream, continuation) = AsyncStream<CmxIrohConnectionPathEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let callback = CmxIrohLibPathEventCallback(continuation: continuation)
        await callback.onEvent(event: .opened(
            id: "first",
            remoteAddr: "192.168.1.10:443",
            localAddr: "192.168.1.2:5000"
        ))
        await callback.onEvent(event: .selected(
            id: "second",
            remoteAddr: "https://relay.example",
            localAddr: "https://relay.example"
        ))
        continuation.finish()

        var events: [CmxIrohConnectionPathEvent] = []
        for await event in stream {
            events.append(event)
        }
        #expect(events == [
            CmxIrohConnectionPathEvent(kind: .lagged, pathKind: .unknown),
        ])
    }

    @Test
    func mapsPathEventsAndClampsApplicationErrorCode() async {
        let log = DiagnosticLog(capacity: 8)
        let recorder = CmxIrohConnectionDiagnosticRecorder(
            diagnosticLog: log,
            sessionID: 23,
            peerAlias: 7
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

        #expect(await waitForDiagnosticProcessedCount(log, atLeast: 6))
        let events = await log.snapshot().events
        #expect(events.map(\.code) == [
            .transportPathEvent,
            .transportPathEvent,
            .transportPathEvent,
            .transportPathEvent,
            .transportCloseAttribution,
            .transportCloseReason,
        ])
        #expect(events.map(\.a) == [1, 2, 3, 4, 2, DiagnosticRemoteCloseReason.unknown.rawValue])
        #expect(events.map(\.b) == [
            DiagnosticPathKind.privateNetwork.rawValue,
            DiagnosticPathKind.direct.rawValue,
            DiagnosticPathKind.relay.rawValue,
            DiagnosticPathKind.unknown.rawValue,
            DiagnosticFailureKind.connectionClosed.rawValue,
            nil,
        ])
        #expect(events.allSatisfy { $0.c == 23 })
        #expect(events.allSatisfy { $0.surface == 7 })
        #expect(events[4].ms == UInt32(Int32.max))
    }
}

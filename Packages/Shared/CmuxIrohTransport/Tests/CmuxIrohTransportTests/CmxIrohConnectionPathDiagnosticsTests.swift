import CMUXMobileCore
import IrohLib
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohConnectionPathDiagnosticsTests {
    @Test func pathInventoryCountsNativeRelayAndNonRelaySnapshots() {
        let snapshots = [
            CmxIrohConnectionPathSnapshot(
                isSelected: true,
                remoteAddress: "192.168.1.10:443",
                isIP: true,
                isRelay: false
            ),
            CmxIrohConnectionPathSnapshot(
                isSelected: false,
                remoteAddress: "relay.example.com",
                isIP: false,
                isRelay: true
            ),
            CmxIrohConnectionPathSnapshot(
                isSelected: false,
                remoteAddress: "100.64.0.2:443",
                isIP: true,
                isRelay: false
            ),
        ]

        let counts = CmxIrohConnectionPathCounts(snapshots: snapshots)

        #expect(counts == CmxIrohConnectionPathCounts(relay: 1, nonRelay: 2))
    }

    @Test func pathInventoryBoundsNativeSnapshotCount() {
        let snapshot = CmxIrohConnectionPathSnapshot(
            isSelected: false,
            remoteAddress: "192.168.1.10:443",
            isIP: true,
            isRelay: false
        )

        let counts = CmxIrohConnectionPathCounts(
            snapshots: Array(repeating: snapshot, count: 100)
        )

        #expect(counts == CmxIrohConnectionPathCounts(relay: 0, nonRelay: 64))
    }

    @Test(arguments: [
        PathEvent.selected(
            id: "private",
            remoteAddr: "192.168.1.10:443",
            localAddr: "192.168.1.2:5000"
        ),
        PathEvent.lagged(missed: 1),
    ])
    func callbackBeforeStartupRecordsInitialSnapshotFirst(event: PathEvent) async {
        let log = DiagnosticLog(capacity: 8)
        let observer = CmxIrohConnectionPathDiagnostics.Observer(
            log: log,
            surface: 7,
            sessionID: 23,
            selectedPath: { .privateNetwork },
            pathCounts: { CmxIrohConnectionPathCounts(relay: 1, nonRelay: 2) }
        )

        // Native callbacks may begin as soon as the watcher is registered,
        // before its owner's initialization task gets to run.
        await observer.onEvent(event: event)

        #expect(await waitForDiagnosticProcessedCount(log, atLeast: 3))
        let events = await log.snapshot().events
        #expect(events.map(\.code) == [
            .selectedPathChanged,
            .transportPathInventory,
            .transportPathEvent,
        ])
        #expect(events.first?.diagnosticPathKind == .privateNetwork)
        #expect(events.allSatisfy { $0.surface == 7 && $0.c == 23 })
        #expect(events[1].a == 1)
        #expect(events[1].b == 2)
    }
}

import CMUXMobileCore
import IrohLib
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohConnectionPathDiagnosticsTests {
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
            log: log, surface: 7, sessionID: 23, selectedPath: { .privateNetwork }
        )

        // Native callbacks may begin as soon as the watcher is registered,
        // before its owner's initialization task gets to run.
        await observer.onEvent(event: event)

        #expect(await waitForDiagnosticProcessedCount(log, atLeast: 2))
        let events = await log.snapshot().events
        #expect(events.map(\.code) == [.selectedPathChanged, .transportPathEvent])
        #expect(events.first?.diagnosticPathKind == .privateNetwork)
        #expect(events.allSatisfy { $0.surface == 7 && $0.c == 23 })
    }
}

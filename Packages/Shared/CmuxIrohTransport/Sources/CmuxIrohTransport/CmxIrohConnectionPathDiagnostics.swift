public import CMUXMobileCore
import Foundation
public import IrohLib

/// Records native Iroh path evidence without exporting addresses or endpoint IDs.
/// Retain this observer for the connection's lifetime. Native closure or release
/// of the observer stops its watcher.
public final class CmxIrohConnectionPathDiagnostics: Sendable {
    private let lifetime: Task<Void, Never>

    public init(connection: Connection, diagnosticLog: DiagnosticLog) {
        let correlation = DiagnosticCorrelation()
        let observer = Observer(
            log: diagnosticLog,
            surface: correlation.handle(for: connection.remoteId().toBytes().base64EncodedString()),
            // A native stable ID may be pointer-sized. Hash it into the bounded,
            // process-local diagnostic vocabulary before sending it off-device.
            sessionID: max(1, Int(correlation.handle(for: String(connection.stableId())) ?? 1)),
            selectedPath: {
                CmxIrohObservedConnectionPath(
                    snapshots: connection.paths().map(CmxIrohConnectionPathSnapshot.init)
                ).diagnosticPathKind
            }
        )
        // Subscribe first. The observer serializes its initial snapshot with
        // callbacks, including those delivered before the lifetime task runs.
        let handle = connection.watchPathEvents(callback: observer)
        lifetime = Task {
            await withTaskCancellationHandler {
                await observer.recordInitialPath()
                _ = await connection.closed()
                await handle.stop()
            } onCancel: {
                Task { await handle.stop() }
            }
        }
    }

    deinit { lifetime.cancel() }

    actor Observer: PathEventCallback {
        let log: DiagnosticLog
        let surface: UInt32?
        let sessionID: Int
        let selectedPath: @Sendable () -> DiagnosticPathKind
        private var hasRecordedInitialPath = false

        init(
            log: DiagnosticLog,
            surface: UInt32?,
            sessionID: Int,
            selectedPath: @escaping @Sendable () -> DiagnosticPathKind
        ) {
            self.log = log
            self.surface = surface
            self.sessionID = sessionID
            self.selectedPath = selectedPath
        }

        func onEvent(event: PathEvent) async {
            recordInitialPath()
            let redacted = CmxIrohConnectionPathEvent(event)
            log.record(DiagnosticEvent(
                .transportPathEvent, surface: surface,
                a: redacted.kind.rawValue, b: redacted.pathKind.rawValue, c: sessionID
            ))
            if redacted.kind == .selected || redacted.kind == .lagged {
                // A lost event does not imply the previous path is still selected.
                recordSelectedPath()
            }
        }

        func recordInitialPath() {
            // Whichever arrives first, startup or a callback, owns the initial
            // snapshot. Sampling and recording never suspend on this actor.
            guard !hasRecordedInitialPath else { return }
            hasRecordedInitialPath = true
            recordSelectedPath()
        }

        private func recordSelectedPath() {
            let selected = selectedPath()
            log.record(DiagnosticEvent(
                .selectedPathChanged, surface: surface,
                a: selected.rawValue, c: sessionID
            ))
        }
    }
}

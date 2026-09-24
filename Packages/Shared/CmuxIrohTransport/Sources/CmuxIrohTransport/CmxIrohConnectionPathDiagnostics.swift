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
        // Subscribe before the initial snapshot so a selection change between
        // the two cannot go unrecorded; the log drops a duplicate snapshot.
        let handle = connection.watchPathEvents(callback: observer)
        observer.recordSelectedPath()
        lifetime = Task {
            await withTaskCancellationHandler {
                _ = await connection.closed()
                await handle.stop()
            } onCancel: {
                Task { await handle.stop() }
            }
        }
    }

    deinit { lifetime.cancel() }

    final class Observer: PathEventCallback, Sendable {
        let log: DiagnosticLog
        let surface: UInt32?
        let sessionID: Int
        let selectedPath: @Sendable () -> DiagnosticPathKind

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

        func recordSelectedPath() {
            let selected = selectedPath()
            log.record(DiagnosticEvent(
                .selectedPathChanged, surface: surface,
                a: selected.rawValue, c: sessionID
            ))
        }
    }
}

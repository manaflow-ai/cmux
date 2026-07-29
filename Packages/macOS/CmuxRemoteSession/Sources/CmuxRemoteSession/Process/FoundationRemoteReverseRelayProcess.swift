internal import CmuxFoundation
internal import Foundation

/// Foundation-backed handle for one dedicated SSH reverse-relay process.
///
/// `Process` and `Pipe` callbacks cross executor boundaries; all mutation is
/// owned by Foundation while the coordinator serializes its handle access.
final class FoundationRemoteReverseRelayProcess:
    RemoteReverseRelayProcess,
    @unchecked Sendable
{
    let stderrPipe: Pipe

    private let process: Process

    init(process: Process, stderrPipe: Pipe) {
        self.process = process
        self.stderrPipe = stderrPipe
    }

    var isRunning: Bool {
        process.isRunning
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    func startupFailureDetail(gracePeriod: TimeInterval) -> String? {
        if process.isRunning {
            let originalTerminationHandler = process.terminationHandler
            let exitSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { terminated in
                originalTerminationHandler?(terminated)
                exitSemaphore.signal()
            }
            if !process.isRunning {
                exitSemaphore.signal()
            }
            guard exitSemaphore.wait(timeout: .now() + max(0, gracePeriod)) == .success else {
                return nil
            }
        }
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return RemoteSessionCoordinator.bestErrorLine(stderr: stderr)
            ?? "status=\(process.terminationStatus)"
    }

    func terminate() {
        process.terminate()
    }
}

internal import Darwin
internal import Foundation
internal import CmuxRemoteWorkspace

/// Foundation-backed handle for one dedicated SSH reverse-relay process.
///
/// `Process` and `Pipe` callbacks cross executor boundaries; all mutation is
/// protected by the capture state's lock while the coordinator serializes its
/// handle access.
final class FoundationRemoteReverseRelayProcess:
    RemoteReverseRelayProcess,
    @unchecked Sendable
{
    private let process: Process
    private let stderrPipe: Pipe
    private let stderrDrainGracePeriod: TimeInterval
    private let terminationGracePeriod: TimeInterval
    private let clock: any RemoteProxyRetryClock

    init(
        process: Process,
        stderrPipe: Pipe,
        stderrDrainGracePeriod: TimeInterval = 0.5,
        terminationGracePeriod: TimeInterval = 2,
        clock: any RemoteProxyRetryClock = SystemRemoteProxyRetryClock()
    ) {
        self.process = process
        self.stderrPipe = stderrPipe
        self.stderrDrainGracePeriod = stderrDrainGracePeriod
        self.terminationGracePeriod = terminationGracePeriod
        self.clock = clock
    }

    var isRunning: Bool {
        process.isRunning
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    /// Drains stderr without parking one utility worker for the relay's
    /// lifetime. EOF completes immediately after termination; an inherited
    /// writer that outlives ssh is cut off after a bounded final grace period.
    func captureTermination(
        _ handler: @escaping @Sendable (String?) -> Void
    ) {
        installLifecycleCapture(
            startupMarker: nil,
            startupHandler: nil,
            terminationHandler: handler
        )
    }

    /// Reports exact forward confirmation and eventual process termination
    /// from the same event-driven stderr stream.
    func captureLifecycle(
        startupMarker: String,
        startupTimeout: TimeInterval,
        startupHandler: @escaping @Sendable () -> Void,
        terminationHandler: @escaping @Sendable (String?) -> Void
    ) {
        installLifecycleCapture(
            startupMarker: startupMarker,
            startupTimeout: startupTimeout,
            startupTimeoutHandler: { [weak self] in
                self?.terminate()
            },
            startupHandler: startupHandler,
            terminationHandler: terminationHandler
        )
    }

    private func installLifecycleCapture(
        startupMarker: String?,
        startupTimeout: TimeInterval? = nil,
        startupTimeoutHandler: (@Sendable () -> Void)? = nil,
        startupHandler: (@Sendable () -> Void)?,
        terminationHandler: @escaping @Sendable (String?) -> Void
    ) {
        let readHandle = stderrPipe.fileHandleForReading
        let capture = ReverseRelayStderrCapture(
            readHandle: readHandle,
            drainGracePeriod: stderrDrainGracePeriod,
            startupMarker: startupMarker,
            startupTimeout: startupTimeout,
            startupTimeoutHandler: startupTimeoutHandler,
            startupHandler: startupHandler,
            terminationHandler: terminationHandler,
            clock: clock
        )
        readHandle.readabilityHandler = { handle in
            capture.receive(handle.availableData)
        }
        process.terminationHandler = { terminatedProcess in
            capture.processDidTerminate(status: terminatedProcess.terminationStatus)
        }
        if !process.isRunning {
            capture.processDidTerminate(status: process.terminationStatus)
        }
        capture.startStartupDeadline()
    }

    func terminate() {
        guard process.isRunning else { return }
        let process = process
        let processID = process.processIdentifier
        process.terminate()
        let delayMilliseconds = Int(
            (max(0, terminationGracePeriod) * 1_000).rounded(.up)
        )
        Task { [clock] in
            guard (try? await clock.sleep(
                forMilliseconds: delayMilliseconds
            )) != nil else {
                return
            }
            guard process.isRunning,
                  process.processIdentifier == processID else {
                return
            }
            _ = Darwin.kill(processID, SIGKILL)
        }
    }
}

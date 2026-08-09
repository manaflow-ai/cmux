import Darwin
import Foundation

/// Executes reviewed bytes under a root-owned process deadline.
public struct SudoPrivilegedExecutor {
    /// The private bundled-CLI command invoked only after sudo authenticates.
    public static let hiddenCommand = "__cmux-sudo-privileged-executor"

    private let receiver: SudoPrivilegedScriptReceiver
    private let supervisor: SudoPrivilegedProcessSupervisor
    private let effectiveUserID: @Sendable () -> uid_t
    private let errorDescriptor: Int32
    private let markers: SudoExecutionControlMarkers

    /// Creates the production privileged executor for the bundled CLI.
    public init() {
        receiver = SudoPrivilegedScriptReceiver()
        supervisor = SudoPrivilegedProcessSupervisor()
        effectiveUserID = { geteuid() }
        errorDescriptor = STDERR_FILENO
        markers = SudoExecutionControlMarkers()
    }

    init(
        receiver: SudoPrivilegedScriptReceiver,
        supervisor: SudoPrivilegedProcessSupervisor,
        effectiveUserID: @Sendable @escaping () -> uid_t,
        errorDescriptor: Int32,
        markers: SudoExecutionControlMarkers = SudoExecutionControlMarkers()
    ) {
        self.receiver = receiver
        self.supervisor = supervisor
        self.effectiveUserID = effectiveUserID
        self.errorDescriptor = errorDescriptor
        self.markers = markers
    }

    /// Runs one internal root executor invocation.
    ///
    /// - Parameter arguments: Byte count, absolute deadline, and reviewed display name.
    /// - Returns: The script status or a reserved broker failure status.
    public func run(arguments: [String]) -> Int32 {
        guard effectiveUserID() == 0 else { return 126 }
        guard arguments.count == 3,
              let byteCount = Int(arguments[0]),
              (0...SudoResourcePolicy.standard.maximumScriptBytes).contains(byteCount),
              let deadlineInterval = TimeInterval(arguments[1]),
              deadlineInterval.isFinite else {
            return 2
        }
        let deadline = Date(timeIntervalSince1970: deadlineInterval)
        do {
            return try receiver.withReceivedDescriptor(
                expectedByteCount: byteCount
            ) { descriptor in
                resultCode(
                    supervisor.execute(
                        scriptDescriptor: descriptor,
                        displayName: arguments[2],
                        deadline: deadline
                    )
                )
            }
        } catch {
            emit(markers.transportFailed)
            return 125
        }
    }

    private func resultCode(_ outcome: SudoPrivilegedProcessOutcome) -> Int32 {
        switch outcome {
        case .exited(let code):
            return code
        case .signaled(let signal):
            return min(255, 128 + signal)
        case .timedOut:
            emit(markers.executionTimedOut)
            return 124
        case .cleanupFailed:
            emit(markers.cleanupFailed)
            return 125
        case .launchFailed:
            emit(markers.launchFailed)
            return 126
        }
    }

    private func emit(_ marker: Data) {
        var offset = 0
        while offset < marker.count {
            let count = marker.withUnsafeBytes { bytes in
                Darwin.write(
                    errorDescriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    marker.count - offset
                )
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}

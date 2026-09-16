import Darwin
import Foundation
import os

/// Wakes the synchronous attach reader on termination so its defers restore stdin.
final class SSHPTYAttachSignalMonitor {
    // One-shot signal admission from synchronous DispatchSource callbacks; no actor hop
    // may postpone the shutdown that wakes the blocked attach reader.
    private let receivedSignal = OSAllocatedUnfairLock<Int32?>(initialState: nil)
    private var sources: [DispatchSourceSignal] = []
    private var previousActions: [(Int32, sigaction)] = []

    init(bridgeFD: Int32) throws {
        let descriptor = try ShutdownDescriptor(bridgeFD)
        for number in [SIGHUP, SIGINT, SIGTERM] {
            var previous = sigaction()
            guard sigaction(number, nil, &previous) == 0 else {
                cancel()
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            previousActions.append((number, previous))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            signal(number, SIG_IGN)
            source.setEventHandler { [receivedSignal] in
                let claimed = receivedSignal.withLock { value in
                    guard value == nil else { return false }
                    value = number
                    return true
                }
                if claimed { descriptor.shutdown() }
            }
            sources.append(source)
            source.resume()
        }
    }

    deinit { cancel() }

    func checkCancellation() throws {
        if let number = receivedSignal.withLock({ $0 }) {
            throw CLIError(message: "", exitCode: 128 + number)
        }
    }

    func cancel() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for (number, var action) in previousActions {
            _ = sigaction(number, &action, nil)
        }
        previousActions.removeAll()
    }

    /// Each callback retains its own descriptor lifetime through cancellation.
    /// Immutable fd: shutdown is thread-safe, and deinit runs after all callbacks.
    private final class ShutdownDescriptor: Sendable {
        let fd: Int32
        init(_ bridgeFD: Int32) throws {
            fd = dup(bridgeFD)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        deinit { Darwin.close(fd) }
        func shutdown() { _ = Darwin.shutdown(fd, SHUT_RDWR) }
    }
}

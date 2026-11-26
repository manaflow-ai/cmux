import Darwin
import Foundation
import os

/// Wakes the synchronous attach reader on termination so its defers restore stdin.
public final class SSHPTYAttachSignalMonitor {
    // One-shot signal admission from synchronous DispatchSource callbacks; no actor hop
    // may postpone the shutdown that wakes the blocked attach reader.
    private let receivedSignal = OSAllocatedUnfairLock<Int32?>(initialState: nil)
    private let outputCancellation: PipeCancellationSignal
    private var sources: [DispatchSourceSignal] = []
    private var previousActions: [(Int32, sigaction)] = []

    /// Monitors process termination for one synchronous attach.
    /// - Parameter bridgeFD: Connected socket whose blocked reader must wake.
    /// - Throws: A POSIX error if the descriptor or signal action cannot be captured.
    public init(bridgeFD: Int32) throws {
        outputCancellation = try PipeCancellationSignal()
        let descriptor = try SSHPTYShutdownDescriptor(bridgeFD)
        for number in [SIGHUP, SIGINT, SIGTERM, SIGQUIT] {
            var previous = sigaction()
            guard sigaction(number, nil, &previous) == 0 else {
                cancel()
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            previousActions.append((number, previous))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            signal(number, SIG_IGN)
            source.setEventHandler { [receivedSignal, outputCancellation] in
                let claimed = receivedSignal.withLock { value in
                    guard value == nil else { return false }
                    value = number
                    return true
                }
                if claimed {
                    outputCancellation.cancelReaders()
                    descriptor.shutdown()
                }
            }
            sources.append(source)
            source.resume()
        }
    }

    deinit { cancel() }

    /// The first termination signal observed by this attach.
    public var cancellationSignal: Int32? { receivedSignal.withLock { $0 } }

    /// Waits on output readiness and cancellation in one kernel wait.
    func waitUntilWritable(_ descriptor: Int32) -> Bool {
        while cancellationSignal == nil {
            var descriptors = [
                pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0),
                pollfd(fd: outputCancellation.readDescriptor, events: Int16(POLLIN), revents: 0)
            ]
            let result = Darwin.poll(&descriptors, 2, -1)
            if result < 0, errno == EINTR { continue }
            return result > 0 && descriptors[1].revents == 0
                && descriptors[0].revents & Int16(POLLOUT) != 0
        }
        return false
    }

    /// Cancels delivery and restores the caller's signal dispositions.
    public func cancel() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for (number, var action) in previousActions {
            _ = sigaction(number, &action, nil)
        }
        previousActions.removeAll()
    }

}

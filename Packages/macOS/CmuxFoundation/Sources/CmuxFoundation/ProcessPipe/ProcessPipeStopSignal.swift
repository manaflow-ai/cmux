import Darwin
import Foundation

/// A one-shot, pollable signal for stopping process-pipe I/O.
///
/// Closing the signal's write end leaves its read end permanently hung up, so
/// every reader polling the same descriptor wakes. Retain the signal until all
/// polling operations have returned; the read descriptor closes at deinit.
public final class ProcessPipeStopSignal: Sendable {
    /// The stable descriptor callers include in their `poll(2)` descriptor set.
    ///
    /// The signal owns this descriptor. Callers must not close it and must stop
    /// polling before releasing the signal.
    public let readFileDescriptor: Int32

    private let writeFileDescriptor: Int32
    private let didSignal = AtomicBooleanGate(false)

    /// Creates a close-on-exec pipe used exclusively as a stop signal.
    ///
    /// - Throws: A ``POSIXError`` when the pipe or close-on-exec flags cannot
    ///   be created.
    public init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        readFileDescriptor = descriptors[0]
        writeFileDescriptor = descriptors[1]
    }

    /// Wakes every poller. Repeated calls are safe and have no effect.
    public func signal() {
        guard didSignal.compareExchange(expected: false, desired: true) else {
            return
        }
        Darwin.close(writeFileDescriptor)
    }

    deinit {
        signal()
        Darwin.close(readFileDescriptor)
    }
}

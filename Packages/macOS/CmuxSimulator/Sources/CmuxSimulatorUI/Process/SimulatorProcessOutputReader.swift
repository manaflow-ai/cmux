import Darwin
import Foundation
import os

nonisolated private let outputReaderLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "SimulatorProcessOutputReader"
)

// SAFETY: descriptors are immutable after initialization. `cancel()` only
// writes to the pipe, while the single owned reader thread closes read ends.
// The first failure is published synchronously through failureState's lock.
final class SimulatorProcessOutputReader: @unchecked Sendable {
    private let descriptor: Int32
    private let cancellationReadDescriptor: Int32
    private let cancellationWriteDescriptor: Int32
    // Publishes a one-time result from synchronous POSIX calls before stream completion.
    private let failureState = OSAllocatedUnfairLock<SimulatorProcessOutputFailure?>(initialState: nil)

    /// The first reader failure, set before stream completion; nil for clean EOF or cancellation.
    var failure: SimulatorProcessOutputFailure? { failureState.withLock { $0 } }

    init(fileDescriptor: Int32) {
        let duplicatedDescriptor = dup(fileDescriptor)
        guard duplicatedDescriptor >= 0 else {
            let errorNumber = errno
            descriptor = -1
            cancellationReadDescriptor = -1
            cancellationWriteDescriptor = -1
            Self.recordFailure(.duplicateDescriptor(errorNumber: errorNumber), in: failureState)
            return
        }
        var cancellationDescriptors: [Int32] = [-1, -1]
        if pipe(&cancellationDescriptors) == 0 {
            descriptor = duplicatedDescriptor
            cancellationReadDescriptor = cancellationDescriptors[0]
            cancellationWriteDescriptor = cancellationDescriptors[1]
            _ = fcntl(cancellationWriteDescriptor, F_SETFL, O_NONBLOCK)
            _ = fcntl(cancellationWriteDescriptor, F_SETNOSIGPIPE, 1)
        } else {
            let errorNumber = errno
            Darwin.close(duplicatedDescriptor)
            descriptor = -1
            cancellationReadDescriptor = -1
            cancellationWriteDescriptor = -1
            Self.recordFailure(.cancellationPipe(errorNumber: errorNumber), in: failureState)
        }
    }

    deinit {
        cancel()
        if cancellationWriteDescriptor >= 0 {
            Darwin.close(cancellationWriteDescriptor)
        }
    }

    func cancel() {
        guard cancellationWriteDescriptor >= 0 else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(cancellationWriteDescriptor, &byte, 1)
    }

    func batches() -> AsyncStream<[String]> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [String].self,
            bufferingPolicy: .bufferingNewest(16)
        )
        guard descriptor >= 0 else {
            continuation.finish()
            return stream
        }
        let descriptor = descriptor
        let cancellationReadDescriptor = cancellationReadDescriptor
        // Do not retain the reader: deinit must still be able to wake this thread.
        let failureState = failureState
        let thread = Thread {
            defer {
                Darwin.close(descriptor)
                if cancellationReadDescriptor >= 0 {
                    Darwin.close(cancellationReadDescriptor)
                }
                continuation.finish()
            }
            var batcher = SimulatorProcessOutputBatcher()
            var bytes = [UInt8](repeating: 0, count: 8_192)
            while true {
                var descriptors = [
                    pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0),
                    pollfd(fd: cancellationReadDescriptor, events: Int16(POLLIN), revents: 0),
                ]
                let pollResult = Darwin.poll(&descriptors, nfds_t(descriptors.count), -1)
                if pollResult < 0 {
                    let errorNumber = errno
                    if errorNumber == EINTR { continue }
                    Self.recordFailure(.poll(errorNumber: errorNumber), in: failureState)
                    break
                }
                if descriptors[1].revents != 0 { break }
                if pollResult == 0 { continue }
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count < 0 {
                    let errorNumber = errno
                    if errorNumber == EINTR { continue }
                    Self.recordFailure(.read(errorNumber: errorNumber), in: failureState)
                    break
                }
                if count == 0 { break }
                for batch in batcher.append(Data(bytes.prefix(count))) {
                    continuation.yield(batch)
                }
            }
            if let batch = batcher.finish(), !batch.isEmpty {
                continuation.yield(batch)
            }
        }
        thread.name = "cmux-simulator-process-output"
        thread.stackSize = 1 << 20
        thread.start()
        return stream
    }

    private static func recordFailure(
        _ failure: SimulatorProcessOutputFailure,
        in state: OSAllocatedUnfairLock<SimulatorProcessOutputFailure?>
    ) {
        let isFirstFailure = state.withLock { current in
            guard current == nil else { return false }
            current = failure
            return true
        }
        if isFirstFailure {
            outputReaderLogger.error("Simulator process output failed: \(String(describing: failure), privacy: .public)")
        }
    }
}

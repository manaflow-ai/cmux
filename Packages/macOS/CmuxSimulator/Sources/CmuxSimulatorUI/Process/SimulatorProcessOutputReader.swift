import Darwin
import Foundation

final class SimulatorProcessOutputReader: @unchecked Sendable {
    private let descriptor: Int32
    private let cancellationReadDescriptor: Int32
    private let cancellationWriteDescriptor: Int32

    init(fileDescriptor: Int32) {
        descriptor = dup(fileDescriptor)
        var cancellationDescriptors: [Int32] = [-1, -1]
        if pipe(&cancellationDescriptors) == 0 {
            cancellationReadDescriptor = cancellationDescriptors[0]
            cancellationWriteDescriptor = cancellationDescriptors[1]
            _ = fcntl(cancellationWriteDescriptor, F_SETFL, O_NONBLOCK)
            _ = fcntl(cancellationWriteDescriptor, F_SETNOSIGPIPE, 1)
        } else {
            cancellationReadDescriptor = -1
            cancellationWriteDescriptor = -1
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
                if cancellationReadDescriptor >= 0 {
                    var descriptors = [
                        pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0),
                        pollfd(fd: cancellationReadDescriptor, events: Int16(POLLIN), revents: 0),
                    ]
                    var pollResult: Int32
                    repeat {
                        pollResult = Darwin.poll(&descriptors, nfds_t(descriptors.count), -1)
                    } while pollResult < 0 && errno == EINTR
                    if pollResult <= 0 || descriptors[1].revents != 0 { break }
                }
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
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
}

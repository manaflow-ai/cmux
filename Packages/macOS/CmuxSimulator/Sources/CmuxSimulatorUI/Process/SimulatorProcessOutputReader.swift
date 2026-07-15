import Darwin
import Foundation

final class SimulatorProcessOutputReader: Sendable {
    private let descriptor: Int32

    init(fileDescriptor: Int32) {
        descriptor = dup(fileDescriptor)
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
        let thread = Thread {
            defer {
                Darwin.close(descriptor)
                continuation.finish()
            }
            var batcher = SimulatorProcessOutputBatcher()
            var bytes = [UInt8](repeating: 0, count: 8_192)
            while true {
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

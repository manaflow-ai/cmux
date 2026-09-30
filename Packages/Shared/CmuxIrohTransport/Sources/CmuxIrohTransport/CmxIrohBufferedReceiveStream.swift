import Foundation

/// Preserves bytes read beyond a lane header before delegating to Iroh.
actor CmxIrohBufferedReceiveStream: CmxIrohReceiveStream {
    private let base: any CmxIrohReceiveStream
    private var buffer: Data

    init(base: any CmxIrohReceiveStream, buffer: Data) {
        self.base = base
        self.buffer = buffer
    }

    func receive(maximumByteCount: Int) async throws -> Data? {
        guard maximumByteCount > 0 else {
            throw CmxIrohClientSessionError.invalidMaximumByteCount(maximumByteCount)
        }
        if !buffer.isEmpty {
            let count = min(maximumByteCount, buffer.count)
            let value = Data(buffer.prefix(count))
            buffer.removeFirst(count)
            return value
        }
        return try await base.receive(maximumByteCount: maximumByteCount)
    }

    func stop(errorCode: UInt64) async {
        buffer.removeAll(keepingCapacity: false)
        await base.stop(errorCode: errorCode)
    }
}

import Foundation
@testable import CmuxIrohTransport

actor TestIrohReceiveStream: CmxIrohReceiveStream {
    private var buffer: Data
    private var stoppedCodes: [UInt64] = []

    init(buffer: Data) {
        self.buffer = buffer
    }

    func receive(maximumByteCount: Int) throws -> Data? {
        guard maximumByteCount > 0 else {
            throw CmxIrohClientSessionError.invalidMaximumByteCount(maximumByteCount)
        }
        guard !buffer.isEmpty else { return nil }
        let count = min(maximumByteCount, buffer.count)
        let value = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return value
    }

    func stop(errorCode: UInt64) {
        stoppedCodes.append(errorCode)
    }

    func observedStoppedCodes() -> [UInt64] {
        stoppedCodes
    }
}

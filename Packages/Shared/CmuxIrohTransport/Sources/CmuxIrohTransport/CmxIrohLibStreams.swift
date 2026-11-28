import Foundation
import IrohLib

struct CmxIrohLibSendStream: CmxIrohSendStream {
    let driver: SendStream

    func send(_ data: Data) async throws {
        try await driver.writeAll(buf: data)
    }

    func finish() async throws {
        try await driver.finish()
    }

    func reset(errorCode: UInt64) async {
        try? await driver.reset(errorCode: errorCode)
    }

    func setPriority(_ priority: Int32) async throws {
        try await driver.setPriority(p: priority)
    }
}

struct CmxIrohLibReceiveStream: CmxIrohReceiveStream {
    let driver: RecvStream

    func receive(maximumByteCount: Int) async throws -> Data? {
        guard let limit = UInt32(exactly: maximumByteCount), limit > 0 else {
            throw CmxIrohLibError.invalidReceiveLimit(maximumByteCount)
        }
        let data = try await driver.read(sizeLimit: limit)
        return data.isEmpty ? nil : data
    }

    func stop(errorCode: UInt64) async {
        try? await driver.stop(errorCode: errorCode)
    }
}

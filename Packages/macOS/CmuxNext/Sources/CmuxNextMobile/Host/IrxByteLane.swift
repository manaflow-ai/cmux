import CmuxIrxTransport
import Foundation

/// An admitted irx lane as a `MobileByteLane` (the phone side of a splice).
struct IrxByteLane: MobileByteLane {
    let lane: IrxLaneStream

    func read(maximumBytes: Int) async throws -> Data? {
        try await lane.reader.readRaw(maximumByteCount: maximumBytes)
    }

    func write(_ data: Data) async throws {
        try await lane.writer.write(data)
    }

    func close() async {
        await lane.close()
    }
}

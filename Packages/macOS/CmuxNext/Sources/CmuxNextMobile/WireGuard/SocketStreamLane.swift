import CmuxWireGuard
import Foundation

/// A tunneled connection from a phone as a `MobileByteLane`, so the daemon
/// splice serves WireGuard phones exactly like irx ones.
struct SocketStreamLane: MobileByteLane {
    let stream: SocketStream

    func read(maximumBytes: Int) async throws -> Data? {
        try await stream.read(maximumBytes: maximumBytes)
    }

    func write(_ data: Data) async throws {
        try await stream.write(data)
    }

    func close() async {
        stream.close()
    }
}

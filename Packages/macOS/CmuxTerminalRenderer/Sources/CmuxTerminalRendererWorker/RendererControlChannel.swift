internal import Foundation
internal import Darwin

enum RendererControlChannelError: Error, Sendable {
    case invalidDescriptor(Int32)
    case readFailed(Int32)
    case writeFailed(Int32)
    case writeReturnedZero
}

/// Owns the inherited bidirectional Unix socket without adding another queue.
final class RendererControlChannel: @unchecked Sendable {
    static let maximumReadChunkLength = 64 * 1_024

    let descriptor: Int32
    private var isClosed = false

    init(descriptor: Int32) throws {
        guard descriptor >= 3, fcntl(descriptor, F_GETFD) >= 0 else {
            throw RendererControlChannelError.invalidDescriptor(descriptor)
        }
        self.descriptor = descriptor
    }

    deinit {
        close()
    }

    func readChunk() async throws -> Data {
        try await Self.readChunk(from: descriptor)
    }

    func write(_ data: Data) async throws {
        try await Self.write(data, to: descriptor)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(descriptor)
    }

    /// A renderer has one long-lived control wait. `@concurrent` keeps that
    /// blocking descriptor off any actor executor without creating a queue per
    /// scene or frame.
    @concurrent
    private static func readChunk(from descriptor: Int32) async throws -> Data {
        var data = Data(count: maximumReadChunkLength)
        while true {
            let count = data.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.removeSubrange(count..<data.count)
                return data
            }
            if count == 0 {
                return Data()
            }
            let code = errno
            if code == EINTR { continue }
            throw RendererControlChannelError.readFailed(code)
        }
    }

    @concurrent
    private static func write(_ data: Data, to descriptor: Int32) async throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if count > 0 {
                offset += count
                continue
            }
            if count == 0 {
                throw RendererControlChannelError.writeReturnedZero
            }
            let code = errno
            if code == EINTR { continue }
            throw RendererControlChannelError.writeFailed(code)
        }
    }
}

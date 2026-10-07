import CmuxMobileHost
import Foundation
import Testing

/// One direction of an in-memory byte pipe.
actor BytePipe {
    private var buffer = Data()
    private var closed = false
    private var waiter: (count: Int, continuation: CheckedContinuation<Data, any Error>)?

    func write(_ data: Data) throws {
        guard !closed else { throw RfbError.closed }
        buffer.append(data)
        serve()
    }

    func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter = (count, continuation)
                serve()
            }
        } onCancel: {
            Task { await self.cancelRead() }
        }
    }

    private func cancelRead() {
        waiter?.continuation.resume(throwing: CancellationError())
        waiter = nil
    }

    func close() {
        closed = true
        serve()
    }

    private func serve() {
        guard let (count, continuation) = waiter else { return }
        if buffer.count >= count {
            let out = Data(buffer.prefix(count))
            buffer.removeFirst(count)
            waiter = nil
            continuation.resume(returning: out)
        } else if closed {
            waiter = nil
            continuation.resume(throwing: RfbError.closed)
        }
    }
}

/// The client's end of an in-memory connection to a scripted VNC server.
struct PipeRfbTransport: RfbTransport {
    let incoming: BytePipe
    let outgoing: BytePipe

    func read(exactly count: Int) async throws -> Data { try await incoming.read(exactly: count) }
    func write(_ data: Data) async throws { try await outgoing.write(data) }
    func close() async {
        await incoming.close()
        await outgoing.close()
    }
}

/// A hand-driven VNC server on the other end of a `PipeRfbTransport`.
struct ScriptedVncServer {
    let toClient = BytePipe()
    let fromClient = BytePipe()

    var transport: PipeRfbTransport { PipeRfbTransport(incoming: toClient, outgoing: fromClient) }

    func send(_ bytes: [UInt8]) async throws { try await toClient.write(Data(bytes)) }
    func send(_ data: Data) async throws { try await toClient.write(data) }
    func read(_ count: Int) async throws -> [UInt8] { [UInt8](try await within { try await fromClient.read(exactly: count) }) }
    func close() async { await toClient.close() }

    /// Concatenates byte groups (keeps long literals cheap to type-check).
    static func join(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }

    static func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }
    static func be32(_ value: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8(value >> $0 & 0xff) } }

    /// RFB 3.8, security None, ServerInit `width x height` named `name`,
    /// then consumes the client's SetPixelFormat, SetEncodings and first
    /// FramebufferUpdateRequest.
    func handshake(width: Int, height: Int, name: String = "vm") async throws {
        try await send(Array("RFB 003.008\n".utf8))
        #expect(try await read(12) == Array("RFB 003.008\n".utf8))
        try await send([1, 1])
        #expect(try await read(1) == [1])
        try await send(Self.be32(0))
        #expect(try await read(1) == [1])
        try await send(Self.join(Self.be16(width), Self.be16(height), [UInt8](repeating: 0, count: 16),
                                 Self.be32(name.utf8.count), Array(name.utf8)))
        _ = try await read(20)
        let encodings = try await read(4)
        _ = try await read(Int(encodings[2]) << 8 | Int(encodings[3]) * 4)
        let request = try await read(10)
        #expect(request[0] == 3)
    }

    /// One FramebufferUpdate with a raw rectangle of a single BGRA colour.
    func raw(x: Int, y: Int, width: Int, height: Int, bgra: [UInt8]) async throws {
        var bytes = Self.join([0, 0], Self.be16(1), Self.be16(x), Self.be16(y), Self.be16(width), Self.be16(height), Self.be32(0))
        for _ in 0..<(width * height) { bytes += bgra }
        try await send(bytes)
    }
}

/// An encoder that records the sizes it saw instead of compressing.
actor RecordingEncoder: BrowserFrameEncoder {
    private(set) var sizes: [(Int, Int)] = []
    private var count = 0

    func encode(_ frame: BrowserCapturedFrame, bitrate: Int, maxFPS: Int, forceKeyframe: Bool) async throws -> BrowserEncodedFrame? {
        sizes.append((frame.pixelWidth, frame.pixelHeight))
        count += 1
        return BrowserEncodedFrame(accessUnit: Data([forceKeyframe ? 0x65 : 0x41, UInt8(count & 0xff)]), isKeyframe: forceKeyframe,
                                   captureMicros: frame.captureMicros, pixelWidth: frame.pixelWidth, pixelHeight: frame.pixelHeight)
    }

    func close() {}
}

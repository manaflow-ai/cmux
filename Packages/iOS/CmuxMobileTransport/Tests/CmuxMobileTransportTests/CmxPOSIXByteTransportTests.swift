import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileTransport

/// Drives the raw peer side of a socketpair with blocking syscalls so the
/// transport under test sees genuine kernel buffering, partial reads, and EOF.
private struct SocketPair {
    let transportfd: Int32
    let peerfd: Int32

    /// Creates a connected `SOCK_STREAM` pair. The transport descriptor is
    /// switched to nonblocking (matching what a real acceptor hands off); the
    /// peer descriptor stays blocking for simple test I/O.
    init() throws {
        var fds: [Int32] = [0, 0]
        let result = fds.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return socketpair(Int32(AF_UNIX), Int32(SOCK_STREAM), 0, base)
        }
        guard result == 0 else {
            throw NSError(domain: "socketpair", code: Int(result))
        }
        transportfd = fds[0]
        peerfd = fds[1]
        let flags = fcntl(fds[0], F_GETFL)
        guard flags >= 0, fcntl(fds[0], F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw NSError(domain: "fcntl", code: Int(errno))
        }
        var yes: Int32 = 1
        _ = setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    func peerWrite(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(peerfd, base + offset, data.count - offset)
                try #require(written > 0)
                offset += written
            }
        }
    }

    /// Reads exactly `count` bytes from the peer side.
    func peerRead(count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let n = buffer.withUnsafeMutableBufferPointer { raw -> Int in
                read(peerfd, raw.baseAddress! + filled, count - filled)
            }
            try #require(n > 0)
            filled += n
        }
        return Data(buffer)
    }

    func closePeer() {
        close(peerfd)
    }

    func closeTransportSide() {
        close(transportfd)
    }
}

@Test func posixTransportExchangesBytesBidirectionally() async throws {
    let pair = try SocketPair()
    let transport = CmxPOSIXByteTransport(acceptedFileDescriptor: pair.transportfd)
    defer { Task { await transport.close() } }

    try await transport.connect()
    try pair.peerWrite(Data("request".utf8))
    #expect(try await transport.receive() == Data("request".utf8))

    try await transport.send(Data("response".utf8))
    #expect(try pair.peerRead(count: "response".utf8.count) == Data("response".utf8))
}

@Test func posixTransportCarriesLargeMultiChunkPayloads() async throws {
    let pair = try SocketPair()
    let transport = CmxPOSIXByteTransport(acceptedFileDescriptor: pair.transportfd)
    defer { Task { await transport.close() } }

    try await transport.connect()
    // 192 KiB forces several 64 KiB receive chunks and a send larger than the
    // typical socket buffer, exercising the partial-write path.
    let payload = Data((0..<192 * 1024).map { UInt8($0 % 251) })
    let writeTask = Task { try pair.peerWrite(payload) }
    var received = Data()
    while received.count < payload.count {
        guard let chunk = try await transport.receive() else {
            Issue.record("stream ended early after \(received.count) bytes")
            break
        }
        received.append(chunk)
    }
    try await writeTask.value
    #expect(received == payload)

    // The peer must drain concurrently with the transport's send: a
    // socketpair buffers far less than 192 KiB, so a send that suspends the
    // test task until completion would deadlock against a later read.
    let echoTask = Task { () -> Data in
        var echoed = Data()
        while echoed.count < payload.count {
            echoed.append(try pair.peerRead(count: 32 * 1024))
        }
        return echoed
    }
    try await transport.send(payload)
    #expect(try await echoTask.value == payload)
}

@Test func posixTransportSurfacesPeerCloseAsEndOfStream() async throws {
    let pair = try SocketPair()
    let transport = CmxPOSIXByteTransport(acceptedFileDescriptor: pair.transportfd)

    try await transport.connect()
    try pair.peerWrite(Data("last-bytes".utf8))
    pair.closePeer()
    // Buffered bytes arrive before the end-of-stream nil.
    #expect(try await transport.receive() == Data("last-bytes".utf8))
    #expect(try await transport.receive() == nil)
    #expect(try await transport.receive() == nil)
}

@Test func posixTransportCloseCompletesInFlightReceiveWithEndOfStream() async throws {
    let pair = try SocketPair()
    let transport = CmxPOSIXByteTransport(acceptedFileDescriptor: pair.transportfd)

    try await transport.connect()
    let receiveTask = Task { try await transport.receive() }
    await Task.yield()
    await transport.close()

    #expect(try await receiveTask.value == nil)
    #expect(try await transport.receive() == nil)
    pair.closePeer()
}

@Test func posixTransportRejectsUseAfterClose() async throws {
    let pair = try SocketPair()
    let transport = CmxPOSIXByteTransport(acceptedFileDescriptor: pair.transportfd)
    try await transport.connect()
    await transport.close()

    await #expect(throws: CmxPOSIXByteTransportError.alreadyClosed) {
        try await transport.connect()
    }
    await #expect(throws: CmxPOSIXByteTransportError.alreadyClosed) {
        try await transport.send(Data("x".utf8))
    }
    pair.closePeer()
}

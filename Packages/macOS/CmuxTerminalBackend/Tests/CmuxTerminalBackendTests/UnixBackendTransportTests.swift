@testable import CmuxTerminalBackend
import Darwin
import Foundation
import Testing

@Suite("Credential-bearing Unix backend transport", .serialized)
struct UnixBackendTransportTests {
    @Test("exact protocol socket exposes kernel peer and preserves line frames")
    func peerIdentityAndRoundTrip() async throws {
        let server = try TestUnixSocketServer()
        async let echo: Void = server.echoOneLine()
        let transport = UnixBackendTransport(path: server.path)

        try await transport.connect()
        let peer = try await transport.peerIdentity()
        #expect(peer.processID == UInt32(getpid()))
        #expect(peer.userID == UInt32(geteuid()))
        var auditToken = audit_token_t()
        auditToken.val = (
            peer.auditToken.word0,
            peer.auditToken.word1,
            peer.auditToken.word2,
            peer.auditToken.word3,
            peer.auditToken.word4,
            peer.auditToken.word5,
            peer.auditToken.word6,
            peer.auditToken.word7
        )
        #expect(audit_token_to_pid(auditToken) == getpid())
        #expect(audit_token_to_euid(auditToken) == geteuid())

        let payload = Data(#"{"cmd":"ping"}"#.utf8)
        try await transport.send(payload)
        #expect(try await transport.receive() == payload)

        await transport.close()
        try await echo
        server.stop()
    }

    @Test("one transport object cannot reconnect onto a recycled descriptor")
    func singleUseConnection() async throws {
        let server = try TestUnixSocketServer()
        async let echo: Void = server.echoOneLine()
        let transport = UnixBackendTransport(path: server.path)

        try await transport.connect()
        let payload = Data("{}".utf8)
        try await transport.send(payload)
        _ = try await transport.receive()
        await transport.close()

        await #expect(throws: BackendProtocolError.alreadyConnected) {
            try await transport.connect()
        }
        try await echo
        server.stop()
    }

    @Test("directional limits accept exact boundaries and reject one byte more")
    func directionalLimitBoundaries() async throws {
        #expect(UnixBackendTransport.defaultMaximumOutboundMessageBytes == 4 * 1_024 * 1_024)
        #expect(UnixBackendTransport.defaultMaximumInboundMessageBytes == 16 * 1_024 * 1_024)

        let server = try TestUnixSocketServer()
        let transport = UnixBackendTransport(
            path: server.path,
            maximumOutboundMessageBytes: 8,
            maximumInboundMessageBytes: 16
        )
        try await transport.connect()
        let connection = try await server.acceptConnection()

        let outboundBoundary = Data(repeating: 0x61, count: 8)
        async let received = connection.receiveLine()
        try await transport.send(outboundBoundary)
        #expect(try await received == outboundBoundary)
        await #expect(throws: BackendProtocolError.oversizedMessage(limit: 8)) {
            try await transport.send(Data(repeating: 0x62, count: 9))
        }

        let inboundBoundary = Data(repeating: 0x63, count: 16)
        try await connection.send(inboundBoundary + Data([0x0A]))
        #expect(try await transport.receive() == inboundBoundary)
        try await connection.send(Data(repeating: 0x64, count: 17) + Data([0x0A]))
        await #expect(throws: BackendProtocolError.oversizedMessage(limit: 16)) {
            try await transport.receive()
        }

        await transport.close()
        connection.close()
        server.stop()
    }

    @Test("a task cancelled before send writes no frame and leaves the socket usable")
    func preCancelledSendWritesNothing() async throws {
        let server = try TestUnixSocketServer()
        let transport = UnixBackendTransport(path: server.path)
        try await transport.connect()
        let connection = try await server.acceptConnection()

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await transport.send(Data("cancelled".utf8))
        }
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        async let received = connection.receiveLine()
        let valid = Data("valid".utf8)
        try await transport.send(valid)
        #expect(try await received == valid)

        await transport.close()
        connection.close()
        server.stop()
    }

    @Test("concurrent senders retain whole-frame serialization")
    func concurrentSendersPreserveFrames() async throws {
        let server = try TestUnixSocketServer()
        let transport = UnixBackendTransport(path: server.path)
        try await transport.connect()
        let connection = try await server.acceptConnection()
        let first = Data(repeating: 0x61, count: 128 * 1_024)
        let second = Data(repeating: 0x62, count: 128 * 1_024)

        async let lines = connection.receiveLines(count: 2)
        async let firstSend: Void = transport.send(first)
        async let secondSend: Void = transport.send(second)
        try await firstSend
        try await secondSend
        let received = try await lines
        #expect(Set(received) == Set([first, second]))

        await transport.close()
        connection.close()
        server.stop()
    }

    @Test("pending write count rejects the newest complete frame")
    func pendingWriteCountIsBounded() async throws {
        let server = try TestUnixSocketServer()
        let transport = UnixBackendTransport(
            path: server.path,
            maximumOutboundMessageBytes: 4 * 1_024 * 1_024,
            maximumInboundMessageBytes: 16,
            maximumPendingWriteCount: 1,
            maximumPendingWriteBytes: 8 * 1_024 * 1_024,
            socketSendBufferBytes: 4_096
        )
        try await transport.connect()
        let connection = try await server.acceptConnection()
        let first = Task {
            try await transport.send(Data(repeating: 0x61, count: 4 * 1_024 * 1_024))
        }
        try await waitForPendingWrites(transport, count: 1)

        await #expect(throws: BackendProtocolError.writeQueueOverflow(
            maximumMessages: 1,
            maximumBytes: 8 * 1_024 * 1_024
        )) {
            try await transport.send(Data("second".utf8))
        }

        await transport.close()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        connection.close()
        server.stop()
    }

    @Test("pending write bytes reject the newest complete frame")
    func pendingWriteBytesAreBounded() async throws {
        let retainedBytes = 4 * 1_024 * 1_024 + 1
        let server = try TestUnixSocketServer()
        let transport = UnixBackendTransport(
            path: server.path,
            maximumOutboundMessageBytes: 4 * 1_024 * 1_024,
            maximumInboundMessageBytes: 16,
            maximumPendingWriteCount: 2,
            maximumPendingWriteBytes: retainedBytes,
            socketSendBufferBytes: 4_096
        )
        try await transport.connect()
        let connection = try await server.acceptConnection()
        let first = Task {
            try await transport.send(Data(repeating: 0x61, count: 4 * 1_024 * 1_024))
        }
        try await waitForPendingWrites(transport, count: 1)

        await #expect(throws: BackendProtocolError.writeQueueOverflow(
            maximumMessages: 2,
            maximumBytes: retainedBytes
        )) {
            try await transport.send(Data("x".utf8))
        }

        await transport.close()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        connection.close()
        server.stop()
    }

    @Test("cancelling a partial write closes and resumes every sender exactly once")
    func partialWriteCancellationClosesAllSenders() async throws {
        let payload = Data(repeating: 0x61, count: 4 * 1_024 * 1_024)
        let server = try TestUnixSocketServer()
        let transport = UnixBackendTransport(
            path: server.path,
            maximumOutboundMessageBytes: payload.count,
            maximumInboundMessageBytes: 16,
            maximumPendingWriteCount: 3,
            maximumPendingWriteBytes: 8 * 1_024 * 1_024,
            socketSendBufferBytes: 4_096
        )
        try await transport.connect()
        let connection = try await server.acceptConnection()
        let first = Task { try await transport.send(payload) }
        try await waitForPendingWrites(transport, count: 1)
        let second = Task { try await transport.send(Data("queued".utf8)) }
        try await waitForPendingWrites(transport, count: 2)
        try await waitForAvailableBytes(connection)

        first.cancel()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        await #expect(throws: CancellationError.self) {
            try await second.value
        }
        let partial = try await connection.drainUntilEOF(timeoutMilliseconds: 1_000)
        #expect(!partial.isEmpty)
        #expect(partial.count < payload.count + 1)

        connection.close()
        server.stop()
    }

    @Test("close-on-exec prevents an exec child from retaining the protocol socket")
    func closeOnExecAllowsImmediateEOF() async throws {
        let server = try TestUnixSocketServer()
        let transport = UnixBackendTransport(path: server.path)
        try await transport.connect()
        let connection = try await server.acceptConnection()
        let child = try spawnSleepProcess()
        defer { terminateAndWait(child) }

        await transport.close()
        #expect(try await connection.drainUntilEOF(timeoutMilliseconds: 500).isEmpty)
        #expect(kill(child, 0) == 0)

        connection.close()
        server.stop()
    }

    private func waitForPendingWrites(
        _ transport: UnixBackendTransport,
        count: Int
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await transport.pendingWriteMetrics().count != count {
            guard clock.now < deadline else { throw CocoaError(.fileWriteUnknown) }
            await Task.yield()
        }
    }

    private func waitForAvailableBytes(_ connection: TestUnixSocketConnection) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while try connection.availableByteCount() == 0 {
            guard clock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            await Task.yield()
        }
    }

    private func spawnSleepProcess() throws -> pid_t {
        var processID: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [
            strdup("sleep"),
            strdup("5"),
            nil,
        ]
        defer {
            for argument in arguments.dropLast() {
                free(argument)
            }
        }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let result = posix_spawn(
            &processID,
            "/bin/sleep",
            nil,
            nil,
            &arguments,
            &environment
        )
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result))
        }
        return processID
    }

    private func terminateAndWait(_ processID: pid_t) {
        _ = kill(processID, SIGKILL)
        var status: Int32 = 0
        while waitpid(processID, &status, 0) < 0, errno == EINTR {}
    }
}

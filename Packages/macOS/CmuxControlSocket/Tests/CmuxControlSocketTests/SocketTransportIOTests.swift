import Darwin
import Foundation
import Testing

@testable import CmuxControlSocket

@Suite struct SocketTransportWriteAllTests {
    let transport = SocketTransport()

    @Test func writeAllWritesCompletePayload() throws {
        let sockets = try UnixSocketFixture.makeSocketPair()
        defer {
            Darwin.close(sockets.reader)
            Darwin.close(sockets.writer)
        }

        let payload = Data("PONG\n".utf8)
        #expect(transport.writeAll(payload, to: sockets.writer))

        var buffer = [UInt8](repeating: 0, count: payload.count)
        let count = Darwin.read(sockets.reader, &buffer, buffer.count)
        #expect(count == payload.count)
        #expect((count > 0 ? Data(buffer.prefix(count)) : Data()) == payload)
    }

    @Test func writeAllReturnsWhenPeerDoesNotRead() throws {
        let sockets = try UnixSocketFixture.makeSocketPair()
        defer {
            Darwin.close(sockets.reader)
            Darwin.close(sockets.writer)
        }
        try UnixSocketFixture.configureSendTimeout(sockets.writer, timeout: 0.05)

        let payload = Data(repeating: 0x78, count: 8 * 1024 * 1024)
        let startedAt = Date()
        #expect(!transport.writeAll(payload, to: sockets.writer))
        #expect(Date().timeIntervalSince(startedAt) < 2.0)
    }
}

@Suite struct SocketTransportProbeCommandTests {
    let transport = SocketTransport()

    @Test func probeCommandReturnsFirstLineResponse() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }

        let handled = UnixSocketFixture.acceptSingleClient(on: listenerFD) { clientFD in
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = read(clientFD, &buffer, buffer.count)
            let response = "PONG\nextra\n"
            _ = response.withCString { ptr in
                write(clientFD, ptr, strlen(ptr))
            }
        }

        let response = transport.probeCommand("ping", at: path, timeout: 0.5)

        #expect(response == "PONG")
        #expect(handled.wait(timeout: .now() + 1.0) == .success)
    }

    @Test func probeCommandTimesOutWithoutPollingUntilServerResponds() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }

        let releaseServer = DispatchSemaphore(value: 0)
        let handled = UnixSocketFixture.acceptSingleClient(on: listenerFD) { clientFD in
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = read(clientFD, &buffer, buffer.count)
            _ = releaseServer.wait(timeout: .now() + 1.0)
        }

        let startedAt = Date()
        let response = transport.probeCommand("ping", at: path, timeout: 0.2)
        let elapsed = Date().timeIntervalSince(startedAt)
        releaseServer.signal()

        #expect(response == nil)
        #expect(elapsed >= 0.18)
        #expect(elapsed < 0.8)
        #expect(handled.wait(timeout: .now() + 1.0) == .success)
    }

    @Test func probeCommandReturnsNilForMissingSocket() {
        #expect(transport.probeCommand("ping", at: UnixSocketFixture.makeTempSocketPath(), timeout: 0.2) == nil)
    }
}

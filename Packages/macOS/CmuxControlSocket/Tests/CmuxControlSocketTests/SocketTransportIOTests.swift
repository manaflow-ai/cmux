import Darwin
import Foundation
import Testing

@testable import CmuxControlSocket

/// A one-shot result holder for handing a background thread's outcome back to
/// the test thread. Safe because every read is ordered after a
/// `DispatchSemaphore` signal that follows the write.
private final class ResultBox: @unchecked Sendable {
    var value: Bool?
}

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

        // The peer never reads, so the kernel send buffer fills and the write
        // blocks until SO_SNDTIMEO fires. writeAll must give up and report
        // failure rather than hanging. Drive it on a background thread and wait
        // on its completion signal: the call returning at all (within a
        // generous deadline) proves it did not hang, and the captured result
        // proves it reported the write failure. The semaphore establishes the
        // happens-before edge for reading `result` after the worker stores it.
        let writer = sockets.writer
        let transport = transport
        let finished = DispatchSemaphore(value: 0)
        let result = ResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            result.value = transport.writeAll(payload, to: writer)
            finished.signal()
        }

        #expect(finished.wait(timeout: .now() + 5.0) == .success)
        #expect(result.value == false)
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

    @Test func probeCommandReturnsTheServerProcessIdentityWithItsResponse() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }

        let handled = UnixSocketFixture.acceptSingleClient(on: listenerFD) { clientFD in
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = read(clientFD, &buffer, buffer.count)
            let response = "PONG\n"
            _ = response.withCString { ptr in
                write(clientFD, ptr, strlen(ptr))
            }
        }

        let result = transport.probeCommandWithPeerProcessID(
            "ping",
            at: path,
            timeout: 0.5
        )

        #expect(result?.response == "PONG")
        #expect(result?.peerProcessID == getpid())
        #expect(handled.wait(timeout: .now() + 1.0) == .success)
    }

    @Test func probeCommandPreservesUTF8SplitAcrossReadBuffers() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }

        let prefix = String(repeating: "a", count: 4_095)
        let scalar = Array("🙂".utf8)
        let handled = UnixSocketFixture.acceptSingleClient(on: listenerFD) {
            clientFD in
            var command = [UInt8](repeating: 0, count: 256)
            _ = read(clientFD, &command, command.count)

            var firstWrite = Data(prefix.utf8)
            firstWrite.append(scalar[0])
            var secondWrite = Data(scalar.dropFirst())
            secondWrite.append(contentsOf: "\n".utf8)
            #expect(SocketTransport().writeAll(firstWrite, to: clientFD))
            #expect(SocketTransport().writeAll(secondWrite, to: clientFD))
        }

        let response = transport.probeCommand("ping", at: path, timeout: 0.5)

        #expect(response == prefix + "🙂")
        #expect(handled.wait(timeout: .now() + 1.0) == .success)
    }

    @Test func probeCommandRejectsPeerBeforeSendingCommand() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }

        let commandReceived = ResultBox()
        let handled = UnixSocketFixture.acceptSingleClient(on: listenerFD) {
            clientFD in
            var buffer = [UInt8](repeating: 0, count: 256)
            commandReceived.value =
                Darwin.read(clientFD, &buffer, buffer.count) > 0
        }

        let result = transport.probeCommandWithPeerProcessID(
            "sensitive-command",
            at: path,
            timeout: 0.5,
            validatingPeer: { _ in false }
        )

        #expect(result?.response == nil)
        #expect(handled.wait(timeout: .now() + 1.0) == .success)
        #expect(commandReceived.value == false)
    }

    @Test func probeCommandTimesOutWithoutPollingUntilServerResponds() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }

        // The server reads the command, signals that it received it, then parks
        // without ever writing a response. The probe must give up on its own
        // SO_RCVTIMEO and return nil instead of polling until the server
        // eventually unblocks.
        let commandReceived = DispatchSemaphore(value: 0)
        let releaseServer = DispatchSemaphore(value: 0)
        let handled = UnixSocketFixture.acceptSingleClient(on: listenerFD) { clientFD in
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = read(clientFD, &buffer, buffer.count)
            commandReceived.signal()
            _ = releaseServer.wait(timeout: .now() + 1.0)
        }

        let response = transport.probeCommand("ping", at: path, timeout: 0.2)

        // The server received the command (so the probe connected and sent),
        // yet the probe returned nil before the server was ever released to
        // respond: the timeout fired on its own rather than the probe blocking
        // until a late response arrived.
        #expect(commandReceived.wait(timeout: .now() + 1.0) == .success)
        #expect(response == nil)
        releaseServer.signal()
        #expect(handled.wait(timeout: .now() + 1.0) == .success)
    }

    @Test func probeCommandReturnsNilForMissingSocket() {
        #expect(transport.probeCommand("ping", at: UnixSocketFixture.makeTempSocketPath(), timeout: 0.2) == nil)
    }
}

@Suite struct PersistentSocketLineConnectionTests {
    @Test func commandsReuseOneAuthenticatedConnectionWithoutAddedLatency() throws {
        let path = UnixSocketFixture.makeTempSocketPath()
        let listenerFD = try UnixSocketFixture.bindListeningSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }
        let handled = UnixSocketFixture.acceptSingleClient(
            on: listenerFD
        ) { clientFD in
            for expected in ["first", "second"] {
                #expect(readLine(from: clientFD) == expected)
                let response = "\(expected)-response\n"
                #expect(SocketTransport().writeAll(
                    Data(response.utf8),
                    to: clientFD
                ))
            }
        }
        let connection = PersistentSocketLineConnection()
        let startedAt = ContinuousClock.now

        let first = connection.command(
            "first",
            at: path,
            timeout: 0.5,
            validatingPeer: { $0 == getpid() }
        )
        let second = connection.command(
            "second",
            at: path,
            timeout: 0.5,
            validatingPeer: { $0 == getpid() }
        )

        #expect(first?.response == "first-response")
        #expect(second?.response == "second-response")
        #expect(ContinuousClock.now - startedAt < .seconds(1))
        connection.invalidate()
        #expect(handled.wait(timeout: .now() + 1.0) == .success)
    }

    private func readLine(from socket: Int32) -> String? {
        var bytes: [UInt8] = []
        while bytes.count < 4_096 {
            var byte: UInt8 = 0
            let count = Darwin.read(socket, &byte, 1)
            guard count > 0 else { return nil }
            if byte == 0x0A {
                return String(data: Data(bytes), encoding: .utf8)
            }
            bytes.append(byte)
        }
        return nil
    }
}

import Darwin
import Foundation
import Testing

@testable import CmuxControlSocket

@Suite struct PersistentSocketLineConnectionTests {
    @Test func commandsReuseOneAuthenticatedConnectionWithoutAddedLatency()
        async throws
    {
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

        let first = await connection.command(
            "first",
            at: path,
            timeout: 0.5,
            validatingPeer: { $0 == getpid() }
        )
        let second = await connection.command(
            "second",
            at: path,
            timeout: 0.5,
            validatingPeer: { $0 == getpid() }
        )

        #expect(first?.response == "first-response")
        #expect(second?.response == "second-response")
        #expect(ContinuousClock.now - startedAt < .seconds(1))
        await connection.invalidate()
        let handledResult = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: handled.wait(timeout: .now() + 1.0)
                )
            }
        }
        #expect(handledResult == .success)
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

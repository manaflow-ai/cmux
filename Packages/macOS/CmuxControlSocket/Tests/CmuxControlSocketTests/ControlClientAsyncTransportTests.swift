import CmuxControlSocket
import Darwin
import Foundation
import Testing

@Suite("Async control-client transport")
struct ControlClientAsyncTransportTests {
    @Test func asyncReaderFramesUtf8WithoutBlockingTheCaller() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer {
            close(pair.reader)
            close(pair.writer)
        }

        let reader = ControlClientAsyncLineReader(socket: pair.reader)
        let firstLine = Task {
            await reader.nextLine(shouldContinueReading: { true })
        }
        let firstPayload = Array("first\nあ\n".utf8)
        firstPayload.withUnsafeBufferPointer { buffer in
            _ = Darwin.write(pair.writer, buffer.baseAddress, buffer.count)
        }

        #expect(await firstLine.value == "first")
        #expect(await reader.nextLine(shouldContinueReading: { true }) == "あ")
    }

    @Test func revocationFinishesAnIdleAsyncReader() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer {
            close(pair.reader)
            close(pair.writer)
        }
        let signal = SocketAuthorizationRevocationSignal()
        let reader = ControlClientAsyncLineReader(
            socket: pair.reader,
            authorizationRevocationSignal: signal
        )
        let pending = Task {
            await reader.nextLine(shouldContinueReading: { true })
        }
        signal.revoke()
        #expect(await pending.value == nil)
    }

    @Test func socketReceiveTimeoutFinishesAnIdleAsyncReader() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer {
            close(pair.reader)
            close(pair.writer)
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 20_000)
        #expect(
            withUnsafePointer(to: &timeout) { pointer in
                setsockopt(
                    pair.reader,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    pointer,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            } == 0
        )
        let reader = ControlClientAsyncLineReader(socket: pair.reader)
        #expect(await reader.nextLine(shouldContinueReading: { true }) == nil)
    }

    @Test func asyncWriterSuspendsOnlyOnWouldBlockAndPreservesBytes() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer {
            close(pair.reader)
            close(pair.writer)
        }
        let writer = ControlClientAsyncWriter(socket: pair.writer)
        let payload = Data("response\n".utf8)
        #expect(await writer.writeAll(payload))

        var bytes = [UInt8](repeating: 0, count: payload.count)
        let count = bytes.withUnsafeMutableBufferPointer { buffer in
            Darwin.read(pair.reader, buffer.baseAddress, buffer.count)
        }
        #expect(count == payload.count)
        #expect(Data(bytes) == payload)
    }
}

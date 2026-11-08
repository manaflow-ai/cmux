@testable import CmuxControlSocket
import Darwin
import Foundation
import Testing

@Suite("CodeRouter async framing")
struct CodeRouterAsyncLineReaderTests {
    private func write(_ value: String, to descriptor: Int32) throws {
        let data = Data(value.utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                try #require(count > 0)
                offset += count
            }
        }
    }

    @Test func beginAllowsOneCompletionAndRejectsThirdFrame() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer { close(pair.reader); close(pair.writer) }
        try await withHandshakeReader(pair.reader) { reader in
            let begin = #"{"method":"coderouter.handoff.begin"}"#
            let complete = #"{"method":"coderouter.handoff.complete"}"#
            try write(begin + "\n" + complete + "\nthird\n", to: pair.writer)
            #expect(await reader.nextLine(shouldContinueReading: { true }) == begin)
            reader.clearLimits()
            reader.allowCodeRouterHandoffCompletion(timeoutMilliseconds: 1000)
            #expect(await reader.nextLine(shouldContinueReading: { true }) == complete)
            #expect(await reader.nextLine(shouldContinueReading: { true }) == nil)
        }
    }

    @Test func armIsOneShot() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer { close(pair.reader); close(pair.writer) }
        try await withHandshakeReader(pair.reader) { reader in
            let arm = #"{"method":"coderouter.handoff.arm"}"#
            try write(arm + "\nnext\n", to: pair.writer)
            #expect(await reader.nextLine(shouldContinueReading: { true }) == arm)
            #expect(await reader.nextLine(shouldContinueReading: { true }) == nil)
        }
    }

    @Test func completionDeadlineEndsIdleConnection() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer { close(pair.reader); close(pair.writer) }
        try await withHandshakeReader(pair.reader) { reader in
            try write(#"{"method":"coderouter.handoff.begin"}"# + "\n", to: pair.writer)
            #expect(await reader.nextLine(shouldContinueReading: { true }) != nil)
            reader.allowCodeRouterHandoffCompletion(timeoutMilliseconds: 1)
            #expect(await reader.nextLine(shouldContinueReading: { true }) == nil)
        }
    }

    @Test(arguments: [
        #"{"method":"coderouter.handoff.arm","padding":""#,
        #"{"padding":""#,
        #"{"method":"normal","padding":""#,
    ])
    func oversizedOrLateHandoffFailsClosed(_ prefix: String) async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer { close(pair.reader); close(pair.writer) }
        try await withHandshakeReader(pair.reader) { reader in
            let frame = prefix + String(repeating: "x", count: 4100) + #"","method":"coderouter.handoff.complete"}"#
            try write(frame + "\n", to: pair.writer)
            #expect(await reader.nextLine(shouldContinueReading: { true }) == nil)
        }
    }

    @Test func oversizedOrdinaryRequestRemainsAllowedBeforeHandshake() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer { close(pair.reader); close(pair.writer) }
        try await withHandshakeReader(pair.reader) { reader in
            let ordinary = #"{"method":"normal","padding":""# + String(repeating: "x", count: 4100) + #""}"#
            let begin = #"{"method":"coderouter.handoff.begin"}"#
            try write(ordinary + "\n" + begin + "\n", to: pair.writer)
            #expect(await reader.nextLine(shouldContinueReading: { true }) == ordinary)
            #expect(await reader.nextLine(shouldContinueReading: { true }) == begin)
        }
    }

    @Test func completionCannotUseOrdinaryRouteToEscapeByteLimit() async throws {
        let pair = try UnixSocketFixture.makeSocketPair()
        defer { close(pair.reader); close(pair.writer) }
        try await withHandshakeReader(pair.reader) { reader in
            try write(#"{"method":"coderouter.handoff.begin"}"# + "\n", to: pair.writer)
            #expect(await reader.nextLine(shouldContinueReading: { true }) != nil)
            reader.allowCodeRouterHandoffCompletion(timeoutMilliseconds: 1000)
            reader.clearLimits()
            try write(#"{"method":"normal","padding":""# + String(repeating: "x", count: 4100) + #""}"# + "\n", to: pair.writer)
            #expect(await reader.nextLine(shouldContinueReading: { true }) == nil)
        }
    }

    /// Runs `body` with a handshake-limited reader and joins its source
    /// cancellation before the caller closes the socket.
    private func withHandshakeReader(
        _ socket: Int32,
        _ body: (ControlClientAsyncLineReader) async throws -> Void
    ) async throws {
        let reader = ControlClientAsyncLineReader(socket: socket, codeRouterHandshakeMaximumBytes: 4096)
        do {
            try await body(reader)
        } catch {
            await reader.cancelAndWait()
            throw error
        }
        await reader.cancelAndWait()
    }
}

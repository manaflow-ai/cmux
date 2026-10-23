@testable import CmuxControlSocket
import Darwin
import Foundation
import Testing

@Suite("Control request line encoding")
struct ControlRequestLineTests {
    /// Larger than the reader's 4 KiB route classification window, and small
    /// enough for one socketpair buffer so the test can write before reading.
    private static let padding = String(repeating: "x", count: 2_500)

    private static func largeRequest(extraKey: String) -> [String: Any] {
        [
            "id": "request-\(extraKey)",
            "method": "surface.respawn",
            "params": [
                "surface_id": "44444444-4444-4444-8444-444444444444",
                "command": Self.padding,
                "tmux_start_command": Self.padding,
                extraKey: true,
            ] as [String: Any],
        ]
    }

    @Test func methodIsTheFirstKeyAndTheRequestRoundTrips() throws {
        let request = Self.largeRequest(extraKey: "focus")
        let line = try ControlRequestLine.encode(request)

        #expect(line.hasPrefix(#"{"method":"surface.respawn","#))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary
        )
        #expect(decoded.isEqual(to: request))
    }

    @Test func largeRequestIsClassifiedAsOrdinaryWithinTheRouteWindow() throws {
        for extraKey in ["a", "focus", "zz", "params_hint", "method_hint"] {
            let line = try ControlRequestLine.encode(Self.largeRequest(extraKey: extraKey))
            let prefix = Array(line.utf8.prefix(4_097))
            #expect(ControlClientLineReader.classifyTopLevelMethod(in: prefix) == false, "extra key \(extraKey)")
        }
    }

    @Test func largeRequestPassesTheAsyncReaderHandshakeCap() async throws {
        let line = try ControlRequestLine.encode(Self.largeRequest(extraKey: "focus"))
        #expect(line.utf8.count > 4_096)
        let pair = try UnixSocketFixture.makeSocketPair()
        defer { close(pair.reader); close(pair.writer) }
        try Self.writeAll(line + "\n", to: pair.writer)

        let reader = ControlClientAsyncLineReader(socket: pair.reader, codeRouterHandshakeMaximumBytes: 4_096)
        let received = await reader.nextLine(shouldContinueReading: { true })
        await reader.cancelAndWait()

        #expect(received == line)
    }

    @Test func largeRequestPassesTheBlockingReaderHandshakeCap() throws {
        let line = try ControlRequestLine.encode(Self.largeRequest(extraKey: "focus"))
        let pair = try UnixSocketFixture.makeSocketPair()
        defer { close(pair.reader); close(pair.writer) }
        try Self.writeAll(line + "\n", to: pair.writer)

        let reader = ControlClientLineReader(socket: pair.reader, codeRouterHandshakeMaximumBytes: 4_096)

        #expect(reader.nextLine(shouldContinueReading: { true }) == line)
    }

    @Test func requestWithOnlyAMethodIsOneKeyObject() throws {
        #expect(try ControlRequestLine.encode(["method": "system.ping"]) == #"{"method":"system.ping"}"#)
    }

    @Test func requestWithoutAMethodKeepsSortedKeys() throws {
        #expect(try ControlRequestLine.encode(["b": 1, "a": 2]) == #"{"a":2,"b":1}"#)
    }

    @Test func invalidJSONObjectThrows() {
        #expect(throws: ControlRequestLine.EncodingError.self) {
            try ControlRequestLine.encode(["method": "x", "params": Date()])
        }
    }

    private static func writeAll(_ value: String, to descriptor: Int32) throws {
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
}

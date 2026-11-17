import Foundation
import Testing
@testable import CmuxNextRemoteView

/// The `cmux.rd/1` control messages against the golden vectors cmux-rd-proto's own tests read
/// (cmux-tui/crates/cmux-rd-proto/tests/vectors/control.json; docs/protocols/index.json lists
/// both sides). Every message the host's `Control` parses, this viewer parses as the same
/// message, and what it writes back parses again unchanged.
@Suite struct RemoteRdControlTests {
    static func vectors() throws -> [[String: Any]] {
        let repo = (0..<6).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let file = repo.appendingPathComponent("cmux-tui/crates/cmux-rd-proto/tests/vectors/control.json")
        let list = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
        return try #require(list)
    }

    static func vector(_ name: String) throws -> [String: Any] {
        try #require(try vectors().first { $0["name"] as? String == name })
    }

    static func parse(_ vector: [String: Any]) throws -> RemoteRdControl {
        let json = try #require(vector["json"])
        return try RemoteRdControl.parse(JSONSerialization.data(withJSONObject: json))
    }

    @Test func everyVectorParsesAsAKnownMessageAndRoundTrips() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count >= 18)
        for vector in vectors {
            let name = try #require(vector["name"] as? String)
            let control = try Self.parse(vector)
            if case let .unknown(tag) = control { Issue.record("\(name): parsed as an unknown message \(tag)") }
            #expect(try RemoteRdControl.parse(control.json()) == control, "\(name)")
        }
    }

    /// The vector's `json` names no service; its top-level `service` ("desktop") is what both
    /// sides must default to (cmux-rd-proto's `a_hello_without_service_is_a_desktop_hello`).
    @Test func aHelloWithoutServiceIsADesktopHello() throws {
        let vector = try Self.vector("hello_before_c1")
        let json = try #require(vector["json"] as? [String: Any])
        #expect(json["service"] == nil)
        let expected = try #require(vector["service"] as? String)
        guard case let .hello(hello) = try Self.parse(vector) else { Issue.record("not a hello"); return }
        #expect(hello.service == expected)
        #expect(hello.caps.isEmpty)
        #expect(hello.token == nil)
    }

    @Test func streamAndServiceMessagesWriteTheVectorsJSON() throws {
        for name in ["stream_open", "stream_open_tiles", "stream_opened", "stream_refused", "stream_close", "service", "cursor_shape"] {
            let vector = try Self.vector(name)
            let written = try JSONSerialization.jsonObject(with: Self.parse(vector).json()) as? NSDictionary
            #expect(written == vector["json"] as? NSDictionary, "\(name)")
        }
    }

    /// The vector's `json.kind` is a kind no build knows ("hologram"); its top-level `kind` is what
    /// both sides read it as ("unknown", cmux-rd-proto's `a_newer_stream_kind_parses_as_unknown`).
    @Test func aNewerStreamKindParsesAsUnknown() throws {
        let vector = try Self.vector("stream_open_newer_kind")
        let json = try #require(vector["json"] as? [String: Any])
        #expect(json["kind"] as? String == "hologram")
        #expect(vector["kind"] as? String == "unknown")
        guard case let .streamOpen(open) = try Self.parse(vector) else { Issue.record("not a stream_open"); return }
        #expect(open.kind == .unknown)
        #expect(open.kind.rawValue == vector["kind"] as? String)
    }
}

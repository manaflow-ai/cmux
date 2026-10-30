import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The requests a mock Mac was sent, in order: method and params.
final class SentRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(String, [String: Any])] = []
    func record(_ method: String, _ params: [String: Any]) { lock.withLock { calls.append((method, params)) } }
    var all: [(String, [String: Any])] { lock.withLock { calls } }
}

/// `AcpmuxConnection.wholeList`: a session list acpmux sends in pages (`nextCursor`, acpmux
/// `Client::whole_list`) is read whole, a list that fits is one request, and a cursor sent
/// twice ends the read with an error rather than a loop or a list cut short.
@Suite struct AcpmuxWholeListTests {
    static func row(_ id: String) -> String {
        #"{"sessionId":"\#(id)","name":"\#(id)","harness":"fake","cwd":"/tmp/w","status":"idle"}"#
    }

    /// A Mac whose `_acpmux/watch` answers `watch`, and whose `_acpmux/sessions` answers
    /// `pages[cursor]` (an empty list for an unknown cursor).
    static func connection(watch: String, pages: [String: String], sent: SentRequests) async throws -> AcpmuxConnection {
        let mac = MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            let params = object["params"] as? [String: Any] ?? [:]
            sent.record(method, params)
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "_acpmux/watch": return [reply(watch)]
            case "_acpmux/sessions": return [reply(pages[params["cursor"] as? String ?? ""] ?? #"{"sessions":[]}"#)]
            default: return [reply("{}")]
            }
        }
        return AcpmuxConnection(channel: try await mac.openChannel(service: "acpmux", args: [:]))
    }

    static func ids(_ rows: [JSONValue]) -> [String] { rows.compactMap { $0["sessionId"]?.stringValue } }

    @Test func twoPagesAreReadWhole() async throws {
        let sent = SentRequests()
        let connection = try await Self.connection(
            watch: #"{"sessions":[\#(Self.row("s1")),\#(Self.row("s2"))],"nextCursor":"c1"}"#,
            pages: ["c1": #"{"sessions":[\#(Self.row("s3"))]}"#],
            sent: sent
        )
        let rows = try await connection.wholeList("_acpmux/watch", ["enabled": .bool(true), "includeTools": .bool(false)])
        #expect(Self.ids(rows) == ["s1", "s2", "s3"])

        let calls = sent.all
        #expect(calls.map(\.0) == ["_acpmux/watch", "_acpmux/sessions"])
        // The rest is read with the same filter, the cursor, and no `enabled`.
        #expect(calls.last?.1["cursor"] as? String == "c1")
        #expect(calls.last?.1["includeTools"] as? Bool == false)
        #expect(calls.last?.1["enabled"] == nil)
    }

    /// An older daemon (or a list that fits) answers once with no cursor: one request, as before.
    @Test func aListThatFitsIsOneRequest() async throws {
        let sent = SentRequests()
        let connection = try await Self.connection(watch: #"{"sessions":[\#(Self.row("s1"))]}"#, pages: [:], sent: sent)
        let rows = try await connection.wholeList("_acpmux/watch", ["enabled": .bool(true)])
        #expect(Self.ids(rows) == ["s1"])
        #expect(sent.all.map(\.0) == ["_acpmux/watch"])
    }

    /// A page that names a cursor already read would loop forever: the read stops with an error
    /// after that page, and no partial list comes back.
    @Test func aRepeatedCursorStopsTheRead() async throws {
        let sent = SentRequests()
        let connection = try await Self.connection(
            watch: #"{"sessions":[\#(Self.row("s1"))],"nextCursor":"c1"}"#,
            pages: ["c1": #"{"sessions":[\#(Self.row("s2"))],"nextCursor":"c1"}"#],
            sent: sent
        )
        await #expect(throws: AcpmuxConnection.RPCError.self) {
            _ = try await connection.wholeList("_acpmux/watch", ["enabled": .bool(true)])
        }
        #expect(sent.all.map(\.0) == ["_acpmux/watch", "_acpmux/sessions"])
    }

    /// A page with no rows ends the list even if it names a cursor: there is nothing to page past.
    @Test func anEmptyPageEndsTheList() async throws {
        let sent = SentRequests()
        let connection = try await Self.connection(
            watch: #"{"sessions":[\#(Self.row("s1"))],"nextCursor":"c1"}"#,
            pages: ["c1": #"{"sessions":[],"nextCursor":"c2"}"#],
            sent: sent
        )
        let rows = try await connection.wholeList("_acpmux/watch", ["enabled": .bool(true)])
        #expect(Self.ids(rows) == ["s1"])
        #expect(sent.all.map(\.0) == ["_acpmux/watch", "_acpmux/sessions"])
    }
}

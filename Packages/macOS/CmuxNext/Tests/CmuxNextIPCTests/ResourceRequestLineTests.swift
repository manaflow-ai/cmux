import Foundation
import Testing
@testable import CmuxNextIPC

/// The generated `cmux.protocol/2` bindings (CmuxNextWireGen's ResourceEmitter) and
/// the envelope builder `ResourceRequestLine` write the same lines the hand-built
/// `ResourceRequestEnvelope` writes today, and read responses into typed results and errors.
///
/// Each golden line spells out what `ResourceRequestEnvelope(...).line()` in CmuxNextDaemon
/// encodes for the same call (DaemonConnection+TerminalResource `writeTerminal`, +Notifications
/// `clearNotifications(terminal:)`, +ColumnUpdate's `screen.get`): sorted keys, unescaped
/// slashes, the id as a decimal string, `machine` and `session` filled in as `current`.
/// CmuxNextDaemonTests' ResourceRequestLineParityTests checks the same calls byte for byte
/// against the hand-built envelope itself.
@Suite struct ResourceRequestLineTests {
    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    @Test func terminalInputWriteEncodesToTodaysLine() throws {
        let request = V2TerminalInputWriteRequest(terminal: ResourceSelector(V2TerminalID(rawValue: "term_1")), text: "ls\n")
        let line = try ResourceRequestLine(id: 7, request: request,
                                           idempotencyKey: ResourceIdempotencyKey("cmux-next-write-k1")).line()
        #expect(Self.text(line) == #"""
            {"id":"7","idempotency_key":"cmux-next-write-k1","operation":"terminal.input.write",\#
            "params":{"machine":"current","session":"current","terminal":"term_1","text":"ls\n"},\#
            "protocol":"cmux.protocol/2","type":"request"}
            """#)
    }

    @Test func notificationClearEncodesToTodaysLine() throws {
        let request = V2NotificationClearRequest(terminalID: V2TerminalID(rawValue: "term_1"))
        let line = try ResourceRequestLine(id: 8, request: request,
                                           idempotencyKey: ResourceIdempotencyKey("cmux-next-notification-clear-k2")).line()
        #expect(Self.text(line) == #"""
            {"id":"8","idempotency_key":"cmux-next-notification-clear-k2","operation":"notification.clear",\#
            "params":{"machine":"current","session":"current","terminal_id":"term_1"},\#
            "protocol":"cmux.protocol/2","type":"request"}
            """#)
    }

    @Test func screenGetEncodesToTodaysLine() throws {
        let line = try ResourceRequestLine(id: 9, request: V2ScreenGetRequest(screen: "scr_1")).line()
        #expect(Self.text(line) == #"""
            {"id":"9","operation":"screen.get","params":{"machine":"current","screen":"scr_1","session":"current"},\#
            "protocol":"cmux.protocol/2","type":"request"}
            """#)
    }

    /// A caller-named owner and session replace the `current` defaults, and an origin claim and a
    /// credential go next to the params, as on the hand-built envelope.
    @Test func namedSelectorsOriginAndCredential() throws {
        var line = ResourceRequestLine(id: 10, request: V2ScreenGetRequest(machine: "machine_a", session: "session_b",
                                                                           screen: "scr_1"))
        line.origin = .object(["claim": .string("page")])
        line.credential = "cred"
        #expect(Self.text(try line.line()) == #"""
            {"credential":"cred","id":"10","operation":"screen.get",\#
            "origin":{"claim":"page"},"params":{"machine":"machine_a","screen":"scr_1","session":"session_b"},\#
            "protocol":"cmux.protocol/2","type":"request"}
            """#)
    }

    @Test func refusesKeysTheDaemonRefuses() {
        for bad in ["", "   ", "a\u{07}b", String(repeating: "k", count: 129)] {
            #expect(throws: ResourceWireError.invalidIdempotencyKey(bad)) { try ResourceIdempotencyKey(bad) }
        }
        #expect((try? ResourceIdempotencyKey(" key with spaces ")) != nil)
    }

    @Test func decodesAMutationResult() throws {
        let line = Data(#"""
            {"protocol":"cmux.protocol/2","type":"response","id":"8","ok":true,"result":\#
            {"value":{"cleared":["notif_1","notif_2"]},"generation":"g1","revision":"12","replayed":false}}
            """#.utf8)
        let response = try V2NotificationClearRequest.Response(line: line, operation: "notification.clear",
                                                                using: JSONDecoder())
        let result = try response.get()
        #expect(result.value.cleared == [V2NotificationID(rawValue: "notif_1"), V2NotificationID(rawValue: "notif_2")])
        #expect(result.revision == "12" && result.generation == "g1" && !result.replayed)
    }

    @Test func decodesATypedError() throws {
        let line = Data(#"""
            {"protocol":"cmux.protocol/2","type":"response","id":"9","ok":false,"error":{"code":"selector.ambiguous",\#
            "message":"more than one screen","details":{"scope":"screen","selector":"api","candidates":["scr_1","scr_2"]},\#
            "retryable":false}}
            """#.utf8)
        let response = try V2ScreenGetRequest.Response(line: line, operation: "screen.get", using: JSONDecoder())
        guard case .failure(let error) = response, case .selectorAmbiguous(let details) = error.details else {
            Issue.record("not a selector.ambiguous failure: \(response)")
            return
        }
        #expect(error.code == "selector.ambiguous" && !error.retryable)
        #expect(details.scope == .screen && details.selector == "api" && details.candidates == ["scr_1", "scr_2"])
        #expect(throws: V2ResourceError.self) { try response.get() }
    }

    /// A code a newer daemon sends keeps its raw details; the catalog's 28 codes are all known.
    @Test func keepsAnUnknownErrorCode() throws {
        let line = Data(#"""
            {"ok":false,"error":{"code":"future.code","message":"m","details":{"n":1},"retryable":true}}
            """#.utf8)
        let response = try V2ScreenGetRequest.Response(line: line, operation: "screen.get", using: JSONDecoder())
        guard case .failure(let error) = response else {
            Issue.record("not a failure")
            return
        }
        #expect(error.details == .unknown(.object(["n": .number(1)])) && error.retryable)
        #expect(V2ResourceError.codes.count == 28 && !V2ResourceError.codes.contains("future.code"))
    }

    /// A known code whose details lack fields the catalog requires (an older daemon) still reads
    /// as that error, with its raw details, instead of failing the whole response line.
    @Test func keepsAKnownErrorCodeWithOtherDetails() throws {
        let line = Data(#"""
            {"ok":false,"error":{"code":"selector.ambiguous","message":"more than one screen",\#
            "details":{"scope":"screen"},"retryable":true}}
            """#.utf8)
        let response = try V2ScreenGetRequest.Response(line: line, operation: "screen.get", using: JSONDecoder())
        guard case .failure(let error) = response else {
            Issue.record("not a failure")
            return
        }
        #expect(error.code == "selector.ambiguous" && error.message == "more than one screen" && error.retryable)
        #expect(error.details == .malformed(.object(["scope": .string("screen")])))
    }

    /// A tagged union decodes by its tag, and one that keeps unknown variants keeps the raw object.
    @Test func decodesTaggedUnions() throws {
        let leaf = try JSONDecoder().decode(V2LayoutNode.self,
                                            from: Data(#"{"kind":"leaf","pane_id":"pane_1","tab_ids":["tab_1"]}"#.utf8))
        guard case .leaf(let value) = leaf else {
            Issue.record("not a leaf: \(leaf)")
            return
        }
        #expect(value.paneID == V2PaneID(rawValue: "pane_1") && value.tabIDs == [V2TabID(rawValue: "tab_1")])
        #expect(value.activeTabID == nil && value.kind == .leaf)
        // Encoding writes the same object back, the absent optional left out.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(leaf), as: UTF8.self)
            == #"{"kind":"leaf","pane_id":"pane_1","tab_ids":["tab_1"]}"#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(V2LayoutNode.self, from: Data(#"{"kind":"spiral"}"#.utf8))
        }
        let unknown = try JSONDecoder().decode(V2SessionEventItem.self, from: Data(#"{"kind":"later","x":true}"#.utf8))
        #expect(unknown == .unknown(tag: "later", raw: .object(["kind": .string("later"), "x": .bool(true)])))
    }
}

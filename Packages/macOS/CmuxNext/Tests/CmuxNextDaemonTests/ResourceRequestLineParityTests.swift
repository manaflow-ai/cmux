import CmuxNextIPC
import Foundation
import Testing
@testable import CmuxNextDaemon

/// p05-ipc-024's acceptance, checked against the code it replaces: the generated
/// `cmux.protocol/2` requests and CmuxNextIPC's `ResourceRequestLine` write the same bytes as
/// today's hand-built `ResourceRequestEnvelope(...).line()` for the same call
/// (DaemonConnection+TerminalResource `writeTerminal`, +Notifications `clearNotifications(terminal:)`,
/// +ColumnUpdate's `screen.get`), so tasks 045 and 047 can move call sites over without changing a
/// line. ResourceRequestLineTests in CmuxNextIPCTests keeps the literal lines as documentation.
struct ResourceRequestLineParityTests {
    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    @Test func terminalInputWriteMatchesTheHandBuiltEnvelope() throws {
        let key = "cmux-next-write-k1"
        let today = ResourceRequestEnvelope(id: 7, operation: "terminal.input.write",
                                            params: ["terminal": .string("term_1"), "text": .string("ls\n")],
                                            idempotencyKey: key)
        let request = V2TerminalInputWriteRequest(terminal: ResourceSelector(V2TerminalID(rawValue: "term_1")),
                                                  text: "ls\n")
        let generated = ResourceRequestLine(id: 7, request: request, idempotencyKey: try ResourceIdempotencyKey(key))
        #expect(Self.text(try generated.line()) == Self.text(try today.line()))
    }

    @Test func notificationClearMatchesTheHandBuiltEnvelope() throws {
        let key = "cmux-next-notification-clear-k2"
        let today = ResourceRequestEnvelope(id: 8, operation: "notification.clear",
                                            params: ["terminal_id": .string("term_1")], idempotencyKey: key)
        let request = V2NotificationClearRequest(terminalID: V2TerminalID(rawValue: "term_1"))
        let generated = ResourceRequestLine(id: 8, request: request, idempotencyKey: try ResourceIdempotencyKey(key))
        #expect(Self.text(try generated.line()) == Self.text(try today.line()))
    }

    @Test func screenGetMatchesTheHandBuiltEnvelope() throws {
        let today = ResourceRequestEnvelope(id: 9, operation: "screen.get", params: ["screen": .string("scr_1")],
                                            idempotencyKey: nil)
        let generated = ResourceRequestLine(id: 9, request: V2ScreenGetRequest(screen: "scr_1"))
        #expect(Self.text(try generated.line()) == Self.text(try today.line()))
    }

    /// Named owner and session, an origin claim and a credential go where the hand-built envelope
    /// puts them.
    @Test func namedSelectorsOriginAndCredentialMatchTheHandBuiltEnvelope() throws {
        var today = ResourceRequestEnvelope(
            id: 10, operation: "screen.get",
            params: ["machine": .string("machine_a"), "session": .string("session_b"), "screen": .string("scr_1")],
            idempotencyKey: nil)
        today.origin = .object(["claim": .string("page")])
        today.credential = "cred"
        let request = V2ScreenGetRequest(machine: "machine_a", session: "session_b", screen: "scr_1")
        let generated = ResourceRequestLine(id: 10, request: request, origin: .object(["claim": .string("page")]),
                                            credential: "cred")
        #expect(Self.text(try generated.line()) == Self.text(try today.line()))
    }
}

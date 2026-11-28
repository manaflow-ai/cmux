import Foundation
import Testing
@testable import CmuxNextDaemon

/// `process-info`, `new-remote-terminal-tab`, `put-blob` and `set-personal-terminal` on the wire: the exact JSON line
/// each sends and the capability that gates it. The four moved from hand-written Swift to types generated from
/// cmux-tui/spec/sdk-schema.json (swift_app/bindings.json); these hold the JSON and the gates the same through that move.
struct GeneratedMirrorRequestWireTests {
    private func line(_ request: some DaemonRequest, id: UInt64 = 1) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: id))
    }

    private func envelope(_ command: String, _ fields: [String: JSONValue]) -> JSONValue {
        .object(fields.merging(["id": .number(1), "cmd": .string(command)]) { $1 })
    }

    @Test func processInfoSendsTheSurfaceAndNeedsNoCapability() throws {
        #expect(try line(TerminalProcessInfoRequest(surface: SurfaceID(rawValue: 7))) ==
            envelope("process-info", ["surface": .number(7)]))
        #expect(TerminalProcessInfoRequest.requiredCapability == nil)
    }

    @Test func aRemoteTerminalTabSendsTheReferenceAndOnlyTheOptionsSet() throws {
        let ref = RemoteTerminalRef(sessionID: "ABC-1", terminalID: TerminalID(rawValue: "t1"), sessionName: "mac")
        #expect(try line(NewRemoteTerminalTabRequest(ref)) ==
            envelope("new-remote-terminal-tab", ["session_id": .string("abc-1"), "terminal_id": .string("t1"), "session_name": .string("mac")]))
        #expect(try line(NewRemoteTerminalTabRequest(ref, pane: PaneID(rawValue: 3), title: "build", size: CellSize(cols: 120, rows: 40))) ==
            envelope("new-remote-terminal-tab", [
                "session_id": .string("abc-1"), "terminal_id": .string("t1"), "session_name": .string("mac"),
                "pane": .number(3), "title": .string("build"), "cols": .number(120), "rows": .number(40),
            ]))
        #expect(NewRemoteTerminalTabRequest.requiredCapability == DaemonCapability.remoteTerminalTabs.rawValue)
    }

    @Test func putBlobSendsTheMediaTypeAndTheBytesInBase64() throws {
        #expect(try line(PutBlobRequest(mediaType: "image/png", data: Data([0, 1, 2, 250]))) ==
            envelope("put-blob", ["media_type": .string("image/png"), "data": .string("AAEC+g==")]))
        #expect(PutBlobRequest.requiredCapability == DaemonCapability.iconAssets.rawValue)
    }

    @Test func aPersonalTerminalThemeSendsNullToClear() throws {
        #expect(try line(SetPersonalTerminalRequest(sessionID: "s", terminalKey: "k", theme: "dracula")) ==
            envelope("set-personal-terminal", ["session_id": .string("s"), "terminal_key": .string("k"), "theme": .string("dracula")]))
        #expect(try line(SetPersonalTerminalRequest(sessionID: "s", terminalKey: "k", theme: nil)) ==
            envelope("set-personal-terminal", ["session_id": .string("s"), "terminal_key": .string("k"), "theme": .null]))
        #expect(SetPersonalTerminalRequest.requiredCapability == DaemonCapability.personalTerminals.rawValue)
    }
}

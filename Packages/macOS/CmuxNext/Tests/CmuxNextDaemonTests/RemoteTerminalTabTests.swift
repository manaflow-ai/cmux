import Foundation
import Testing
@testable import CmuxNextDaemon

/// Remote-terminal tabs (`remote-terminal-tabs-v1`, plans/cmux-next/
/// data-model.md 1.2b): the wire shapes the app speaks and the tab record
/// it mirrors.
@Suite struct RemoteTerminalTabTests {
    private func object<R: DaemonRequest>(_ request: R) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 3)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    static let sessionID = "b0b0b0b0-1111-4111-8111-000000000002"
    static let terminal: TerminalID = "0123456789abcdef0123456789abcdef"

    @Test func aRemoteTerminalTabDecodesItsReference() throws {
        let line = #"""
        {"surface":9,"tab_resource_id":"tab_00000000000000000000000000000009","kind":"remote-terminal","title":"htop",
         "remote":{"session_id":"B0B0B0B0-1111-4111-8111-000000000002","terminal_id":"0123456789abcdef0123456789abcdef","session_name":"build-box"}}
        """#
        let tab = try JSONDecoder().decode(TabSnapshot.self, from: Data(line.utf8))
        #expect(tab.kind == .remoteTerminal)
        #expect(tab.remote == RemoteTerminalRef(sessionID: Self.sessionID, terminalID: Self.terminal, sessionName: "build-box"))
        // The app draws it; the home daemon refuses to attach it.
        #expect(tab.isFrontendOwned)
        #expect(tab.terminalID == nil)
        // An older app sees an unknown kind and no reference.
        let plain = try JSONDecoder().decode(TabSnapshot.self, from: Data(#"{"surface":2,"kind":"pty","remote":{"x":1}}"#.utf8))
        #expect(plain.remote == nil && plain.kind == .pty)
    }

    @Test func requestsUseTheContractFieldNames() throws {
        let ref = RemoteTerminalRef(sessionID: Self.sessionID, terminalID: Self.terminal, sessionName: "build-box")
        let create = try object(NewRemoteTerminalTabRequest(ref, pane: 4, title: "htop", size: CellSize(cols: 100, rows: 30)))
        #expect(create["cmd"] == .string("new-remote-terminal-tab"))
        #expect(create["pane"] == .number(4))
        #expect(create["session_id"] == .string(Self.sessionID))
        #expect(create["terminal_id"] == .string(Self.terminal.rawValue))
        #expect(create["session_name"] == .string("build-box"))
        #expect(create["cols"] == .number(100) && create["rows"] == .number(30))
        let update = try object(UpdateRemoteTerminalTabRequest(surface: 9, title: .set("vim"), snapshot: .clear))
        #expect(update["cmd"] == .string("update-remote-terminal-tab"))
        #expect(update["title"] == .string("vim"))
        #expect(update["snapshot"] == .null)
        #expect(update["session_name"] == nil)
        let read = try object(RemoteTerminalSnapshotRequest(surface: 9))
        #expect(read["cmd"] == .string("remote-terminal-snapshot"))
        #expect(read["surface"] == .number(9))
    }

    @Test func aDetachedTerminalHasNoTab() throws {
        let json = try object(CreateDetachedTerminalRequest(cwd: "/srv", terminalID: Self.terminal,
                                                            mutation: MutationIdentity(origin: "o", mutationID: "m")))
        #expect(json["cmd"] == .string("create-terminal"))
        #expect(json["detached"] == .bool(true) && json["keep"] == .bool(true))
        #expect(json["key"] == nil && json["workspace"] == nil)
        #expect(json["terminal_id"] == .string(Self.terminal.rawValue))
        #expect(json["origin"] == .string("o") && json["mutation_id"] == .string("m"))
        let line = #"{"ok":true,"data":{"surface":null,"pane":null,"terminal_id":"0123456789abcdef0123456789abcdef","terminal_resource_id":"term_aa","lifecycle":"running"}}"#
        let reply = try WireCoding.decodeResponse(CreateDetachedTerminalRequest.Response.self, from: Data(line.utf8))
        #expect(reply.terminalResourceID == "term_aa" && reply.terminalID == Self.terminal)
    }

    @Test func snapshotsAreBoundedToTheDaemonLimit() {
        let line = String(repeating: "é", count: 40) + "\n"
        let text = String(repeating: line, count: 2_000)
        let bounded = UpdateRemoteTerminalTabRequest.bounded(text)
        #expect(bounded.utf8.count <= UpdateRemoteTerminalTabRequest.snapshotLimit)
        // The newest lines stay, and the cut starts on a whole line.
        #expect(text.hasSuffix(bounded))
        #expect(bounded.hasPrefix("é"))
        #expect(UpdateRemoteTerminalTabRequest.bounded("short") == "short")
    }

    @Test func keepReportsThePublicTerminalID() throws {
        let line = #"{"ok":true,"data":{"terminal_id":"0123456789abcdef0123456789abcdef","terminal_resource_id":"term_ffffffffffffffffffffffffffffffff","keep":true}}"#
        let reply = try WireCoding.decodeResponse(SetTerminalKeepRequest.Response.self, from: Data(line.utf8))
        #expect(reply.terminalResourceID == "term_ffffffffffffffffffffffffffffffff")
        let older = #"{"ok":true,"data":{"terminal_id":"0123456789abcdef0123456789abcdef","keep":true}}"#
        #expect(try WireCoding.decodeResponse(SetTerminalKeepRequest.Response.self, from: Data(older.utf8)).terminalResourceID == nil)
    }

    /// A terminal with no tab attaches by id; its `vt-state` names the
    /// surface every later command uses.
    @Test func anUnplacedAttachLearnsItsSurfaceFromVTState() {
        let line = Data(#"{"event":"vt-state","surface":42,"cols":80,"rows":24,"data":""}"#.utf8)
        #expect(TerminalAttachment.initialSurface(name: "vt-state", line: line) == 42)
        let target = TerminalAttachment.Target.unplaced(terminalResourceID: "term_ab", generation: "g1")
        #expect(target.surface == TerminalAttachment.unresolvedSurface)
        #expect(target.terminalResourceID == "term_ab")
        guard case .replay = TerminalAttachment.decodeAttachEvent(name: "vt-state", line: line, surface: 42) else {
            Issue.record("vt-state for the learned surface must pass")
            return
        }
    }
}

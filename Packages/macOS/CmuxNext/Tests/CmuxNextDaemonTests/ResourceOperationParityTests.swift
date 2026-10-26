import CmuxNextIPC
import Foundation
import Testing
@testable import CmuxNextDaemon

/// p05-ipc-045: StateResourceClient and AgentCLIJobCarrier send generated `cmux.protocol/2`
/// requests (`ResourceOperationClient`) instead of hand-built `ResourceRequestEnvelope`s, and
/// every migrated call writes the same line byte for byte as the envelope it replaces. Each
/// expected envelope below is the params dictionary the call site built before the migration.
struct ResourceOperationParityTests {
    private static let key = "cmux-next-parity-k1"

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private static func handBuilt(_ operation: String, _ params: [String: JSONValue],
                                  keyed: Bool = true) throws -> String {
        text(try ResourceRequestEnvelope(id: 11, operation: operation, params: params,
                                         idempotencyKey: keyed ? key : nil).line())
    }

    private static func generated<Request: ResourceMutationRequest>(_ request: Request) throws -> String {
        text(try ResourceRequestLine(id: 11, request: request, idempotencyKey: ResourceIdempotencyKey(key)).line())
    }

    private static func generated<Request: ResourceUnkeyedRequest>(_ request: Request) throws -> String {
        text(try ResourceRequestLine(id: 11, request: request).line())
    }

    private static func id(_ raw: String) -> ResourceID { ResourceID(rawValue: raw) }

    @Test func closedReopenAndDelete() throws {
        #expect(try Self.generated(V2ClosedReopenRequest(closed: "closed_1"))
            == Self.handBuilt("closed.reopen", ["closed": .string("closed_1")]))
        #expect(try Self.generated(StateResourceClient.reopenRequest(tab: "tab_1", fallbackPane: "pane_2"))
            == Self.handBuilt("closed.reopen", ["tab": .string("tab_1"), "fallback_pane": .string("pane_2")]))
        #expect(try Self.generated(StateResourceClient.reopenRequest(tab: "tab_1", fallbackPane: nil))
            == Self.handBuilt("closed.reopen", ["tab": .string("tab_1")]))
        #expect(try Self.generated(V2ClosedDeleteRequest(closed: "closed_1"))
            == Self.handBuilt("closed.delete", ["closed": .string("closed_1")]))
        #expect(try Self.generated(V2ClosedDeleteRequest(all: true, sinceMs: String(UInt64(1_700_000_000_123))))
            == Self.handBuilt("closed.delete", ["all": .bool(true), "since_ms": .string("1700000000123")]))
        #expect(try Self.generated(V2ClosedDeleteRequest(all: true))
            == Self.handBuilt("closed.delete", ["all": .bool(true)]))
    }

    @Test func windowRecords() throws {
        #expect(try Self.generated(V2WindowRecordListRequest())
            == Self.handBuilt("window_record.list", [:], keyed: false))
        let record: JSONValue = .object([
            "frame": .array([.number(0), .number(25.5), .number(1440), .number(900)]),
            "title": .string("a/b \"c\""), "fullscreen": .bool(false), "tabs": .null,
        ])
        #expect(try Self.generated(V2WindowRecordPutRequest(installID: "inst_1", record: ResourceJSON(record),
                                                            windowID: "win_1"))
            == Self.handBuilt("window_record.put", ["install_id": .string("inst_1"), "window_id": .string("win_1"),
                                                    "record": record]))
        #expect(try Self.generated(V2WindowRecordDeleteRequest(installID: "inst_1", windowID: "win_1"))
            == Self.handBuilt("window_record.delete", ["install_id": .string("inst_1"), "window_id": .string("win_1")]))
    }

    @Test func workspaceCreate() throws {
        let focused = StateResourceClient.workspaceCreateRequest(name: nil, ephemeral: true, terminal: true, focus: true,
                                                                daemonSupportsFocus: true)
        #expect(try Self.generated(focused) == Self.handBuilt("workspace.create", [
            "initial_content": .string("terminal"), "ephemeral": .bool(true), "focus": .bool(true),
        ]))
        let named = StateResourceClient.workspaceCreateRequest(name: "showcase", ephemeral: false, terminal: false,
                                                              focus: true, daemonSupportsFocus: false)
        #expect(try Self.generated(named) == Self.handBuilt("workspace.create", [
            "initial_content": .string("empty"), "name": .string("showcase"),
        ]))
    }

    /// `.unchanged` leaves a field out and `.clear` sends `null`, as `StateResourceClient.field` did.
    @Test func workspaceUpdateKeepsClearsAndSets() throws {
        let request = StateResourceClient.workspaceUpdateRequest(
            Self.id("ws_1"), title: .set("Build"), color: .clear, icon: .unchanged, description: .set("notes\n\tline"),
            taskStatus: .set(.needsAttention))
        #expect(try Self.generated(request) == Self.handBuilt("workspace.update", [
            "workspace": .string("ws_1"), "title": .string("Build"), "color": .null,
            "description": .string("notes\n\tline"), "task_status": .string("needs-attention"),
        ]))
        let clearStatus = StateResourceClient.workspaceUpdateRequest(
            Self.id("ws_1"), title: .unchanged, color: .unchanged, icon: .clear, description: .unchanged,
            taskStatus: .clear)
        #expect(try Self.generated(clearStatus) == Self.handBuilt("workspace.update", [
            "workspace": .string("ws_1"), "icon": .null, "task_status": .null,
        ]))
    }

    @Test func workspaceAgentFolder() throws {
        let selector = StateResourceClient.selector(Self.id("ws_1"))
        #expect(try Self.generated(V2WorkspaceAgentFolderSetRequest(workspace: selector, path: "/Users/me/src"))
            == Self.handBuilt("workspace.agent_folder.set", ["workspace": .string("ws_1"), "path": .string("/Users/me/src")]))
        #expect(try Self.generated(V2WorkspaceAgentFolderSetRequest(workspace: selector, path: nil))
            == Self.handBuilt("workspace.agent_folder.set", ["workspace": .string("ws_1"), "path": .null]))
    }

    @Test func tabPinAndUpdate() throws {
        let tab = StateResourceClient.selector(Self.id("tab_1"))
        #expect(try Self.generated(V2TabPinRequest(tab: tab)) == Self.handBuilt("tab.pin", ["tab": .string("tab_1")]))
        #expect(try Self.generated(V2TabUnpinRequest(tab: tab)) == Self.handBuilt("tab.unpin", ["tab": .string("tab_1")]))
        let back = (0..<25).map { "https://example.com/\($0)" }
        let forward = (0..<22).map { "https://example.org/\($0)" }
        let request = StateResourceClient.tabRecordUpdateRequest(Self.id("tab_1"), zoom: .set(1.25), icon: .clear,
                                                                 back: back, forward: forward, markedUnread: true)
        #expect(try Self.generated(request) == Self.handBuilt("tab.update", [
            "tab": .string("tab_1"), "marked_unread": .bool(true), "zoom": .number(1.25), "icon": .null,
            "back": .array(back.suffix(20).map { .string($0) }), "forward": .array(forward.prefix(20).map { .string($0) }),
        ]))
        let zoomOnly = StateResourceClient.tabRecordUpdateRequest(Self.id("tab_1"), zoom: .clear, icon: .unchanged,
                                                                  back: nil, forward: nil, markedUnread: nil)
        #expect(try Self.generated(zoomOnly) == Self.handBuilt("tab.update", ["tab": .string("tab_1"), "zoom": .null]))
    }

    @Test func agentCLIJobWaitExit() throws {
        let request = AgentCLIJobCarrier.waitExitRequest(machine: Self.id("machine_a"), session: Self.id("session_b"),
                                                         terminal: Self.id("term_1"))
        #expect(try Self.generated(request) == Self.handBuilt("terminal.wait_exit", [
            "machine": .string("machine_a"), "session": .string("session_b"), "terminal": .string("term_1"),
            "timeout_ms": .string("5000"),
        ], keyed: false))
    }

    /// The line DaemonConnection sends for a generated request: its operation names the
    /// transport's wait and trace, and its bytes are the envelope builder's.
    @Test func generatedLinesAreDaemonResourceLines() throws {
        let line = ResourceRequestLine(id: 4, request: V2WindowRecordListRequest())
        #expect(line.operation == "window_record.list")
        #expect(try line.lineData() == line.line())
        let envelope = ResourceRequestEnvelope(id: 4, operation: "window_record.list", params: [:], idempotencyKey: nil)
        #expect(envelope.operation == line.operation)
        #expect(try envelope.lineData() == line.lineData())
    }

    @Test func fieldUpdatesMapToTheGeneratedSpelling() {
        #expect(FieldUpdate<String>.unchanged.resourceField { $0 } == .unchanged)
        #expect(FieldUpdate<String>.clear.resourceField { $0 } == .clear)
        #expect(FieldUpdate<WorkspaceTaskStatus>.set(.review).resourceField { $0.rawValue } == .set("review"))
    }
}

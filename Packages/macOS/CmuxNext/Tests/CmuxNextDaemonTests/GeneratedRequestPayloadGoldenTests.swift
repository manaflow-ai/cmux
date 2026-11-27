import Foundation
import Testing
@testable import CmuxNextDaemon

/// Golden payloads for generated requests. These pin the flattened wire shape while
/// the handwritten Swift mirrors move to schema-generated request types.
struct GeneratedRequestPayloadGoldenTests {
    private static let workspaceKey = WorkspaceKey(rawValue: "018f6e21-7b70-7e70-8000-0000000000d1")
    private static let terminalID = TerminalID(rawValue: "018f6e217b707e7080000000000000f1")

    private func line(_ request: some DaemonRequest, id: UInt64 = 7) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: id))
    }

    private func envelope(_ command: String, _ fields: [String: JSONValue], id: JSONValue = .number(7)) -> JSONValue {
        .object(fields.merging(["id": id, "cmd": .string(command)]) { $1 })
    }

    private func baseOptions() -> SpawnOptions {
        SpawnOptions(
            cwd: "/tmp",
            size: CellSize(cols: 80, rows: 24),
            env: ["LANG": "C"],
            workspace: Self.workspaceKey,
            keep: true
        )
    }

    private func spawnFields(_ extras: [String: JSONValue] = [:]) -> [String: JSONValue] {
        extras.merging([
            "cwd": .string("/tmp"),
            "cols": .number(80),
            "rows": .number(24),
            "env": .object(["LANG": .string("C")]),
            "keep": .bool(true),
        ]) { current, _ in current }
    }

    @Test func creationRequestsFlattenTheirSharedOptions() throws {
        var tabOptions = baseOptions()
        tabOptions.terminalID = Self.terminalID
        tabOptions.shellArgs = ["-l"]
        #expect(try line(NewTabRequest(
            pane: PaneID(rawValue: 3),
            options: tabOptions
        )) == envelope("new-tab", spawnFields([
            "pane": .number(3),
            "terminal_id": .string(Self.terminalID.rawValue),
            "shell_args": .array([.string("-l")]),
        ])))

        var splitOptions = baseOptions()
        splitOptions.terminalID = Self.terminalID
        splitOptions.shellArgs = ["-l"]
        splitOptions.paneID = "pane-client-1"
        splitOptions.tabID = "tab-client-1"
        splitOptions.splitID = "split-client-1"
        splitOptions.around = SplitID(rawValue: 9)
        #expect(try line(SplitRequest(
            pane: PaneID(rawValue: 3),
            direction: .right,
            tab: SurfaceID(rawValue: 8),
            options: splitOptions,
            before: true
        )) == envelope("split", spawnFields([
            "pane": .number(3),
            "dir": .string("right"),
            "before": .bool(true),
            "terminal_id": .string(Self.terminalID.rawValue),
            "shell_args": .array([.string("-l")]),
            "pane_id": .string("pane-client-1"),
            "tab_id": .string("tab-client-1"),
            "split_id": .string("split-client-1"),
            "around": .number(9),
        ])))

        var columnOptions = baseOptions()
        columnOptions.paneID = "pane-client-2"
        columnOptions.tabID = "tab-client-2"
        #expect(try line(NewColumnRequest(
            pane: PaneID(rawValue: 3),
            width: 0.75,
            left: true,
            options: columnOptions
        )) == envelope("new-pane-right", spawnFields([
            "pane": .number(3),
            "width": .number(0.75),
            "side": .string("left"),
            "pane_id": .string("pane-client-2"),
            "tab_id": .string("tab-client-2"),
        ])))

        var rowOptions = baseOptions()
        rowOptions.paneID = "pane-client-3"
        rowOptions.tabID = "tab-client-3"
        #expect(try line(NewRowRequest(
            pane: PaneID(rawValue: 3),
            height: 400,
            options: rowOptions
        )) == envelope("new-row", spawnFields([
            "pane": .number(3),
            "height_permille": .number(400),
            "pane_id": .string("pane-client-3"),
            "tab_id": .string("tab-client-3"),
        ])))
    }

    @Test func closeRequestsEncodeOnlyEnabledOptions() throws {
        #expect(try line(CloseTabGroupRequest(group: TabGroupID("group-1"))) ==
            envelope("close-tab-group", ["group": .string("group-1")]))
        #expect(try line(ClosePaneRequest(pane: PaneID(rawValue: 3), endTerminals: true)) ==
            envelope("close-pane", ["pane": .number(3), "end_terminals": .bool(true)]))
        #expect(try line(CloseScreenRequest(screen: ScreenID(rawValue: 4))) ==
            envelope("close-screen", ["screen": .number(4)]))

        let mutation = MutationIdentity(origin: "golden-test", mutationID: "mutation-close", expectedRevision: UInt64.max)
        #expect(try line(CloseTabsRequest(
            surfaces: [SurfaceID(rawValue: 2), SurfaceID(rawValue: 5)],
            endTerminals: true,
            transaction: ClientTransactionID(rawValue: "tx-close"),
            mutation: mutation,
            reason: .sessionEnd
        )) == envelope("close-tabs", [
            "surfaces": .array([.number(2), .number(5)]),
            "end_terminals": .bool(true),
            "transaction": .string("tx-close"),
            "reason": .string("session_end"),
            "origin": .string("golden-test"),
            "mutation_id": .string("mutation-close"),
            "expected_revision": .number(Double(UInt64.max)),
        ]))
    }

    @Test func createTerminalKeepsPostInitShellAndWorkspaceFields() throws {
        let mutation = MutationIdentity(origin: "golden-test", mutationID: "mutation-terminal", expectedRevision: UInt64.max)
        var request = CreateTerminalRequest(
            workspace: .key(Self.workspaceKey),
            argv: ["bash"],
            command: "bash",
            cwd: "/tmp",
            name: "build",
            size: CellSize(cols: 100, rows: 30),
            terminalID: Self.terminalID,
            env: ["LANG": "C"],
            keep: true,
            mutation: mutation
        )
        request.shellArgs = ["-l"]
        request.createWorkspace = true
        request.workspaceName = "Build"

        #expect(try line(request) == envelope("create-terminal", [
            "key": .string(Self.workspaceKey.rawValue),
            "argv": .array([.string("bash")]),
            "command": .string("bash"),
            "cwd": .string("/tmp"),
            "name": .string("build"),
            "cols": .number(100),
            "rows": .number(30),
            "terminal_id": .string(Self.terminalID.rawValue),
            "env": .object(["LANG": .string("C")]),
            "keep": .bool(true),
            "shell_args": .array([.string("-l")]),
            "create_workspace": .bool(true),
            "workspace_name": .string("Build"),
            "origin": .string("golden-test"),
            "mutation_id": .string("mutation-terminal"),
            "expected_revision": .number(Double(UInt64.max)),
        ]))
    }

    @Test func workspaceMutationsFlattenReferencesAndMutationKeys() throws {
        let mutation = MutationIdentity(origin: "golden-test", mutationID: "mutation-workspace", expectedRevision: UInt64.max)
        #expect(try line(RenameWorkspaceRequest(
            workspace: .key(Self.workspaceKey),
            name: "Build",
            source: .auto,
            expectedNameRevision: UInt64.max,
            release: true,
            mutation: mutation
        )) == envelope("rename-workspace", [
            "key": .string(Self.workspaceKey.rawValue),
            "name": .string("Build"),
            "source": .string("auto"),
            "expected_name_revision": .string(String(UInt64.max)),
            "release": .bool(true),
            "origin": .string("golden-test"),
            "mutation_id": .string("mutation-workspace"),
            "expected_revision": .number(Double(UInt64.max)),
        ]))
        #expect(try line(MoveWorkspaceRequest(
            workspace: .key(Self.workspaceKey),
            index: 2,
            mutation: mutation
        )) == envelope("move-workspace", [
            "key": .string(Self.workspaceKey.rawValue),
            "index": .number(2),
            "origin": .string("golden-test"),
            "mutation_id": .string("mutation-workspace"),
            "expected_revision": .number(Double(UInt64.max)),
        ]))
        #expect(try line(CloseWorkspaceRequest(
            workspace: .key(Self.workspaceKey),
            endTerminals: true,
            reason: .sessionEnd,
            ifEmpty: true,
            mutation: mutation,
            reportClosedIDs: true
        )) == envelope("close-workspace", [
            "key": .string(Self.workspaceKey.rawValue),
            "end_terminals": .bool(true),
            "reason": .string("session_end"),
            "if_empty": .bool(true),
            "origin": .string("golden-test"),
            "mutation_id": .string("mutation-workspace"),
            "expected_revision": .number(Double(UInt64.max)),
        ]))
    }

    @Test func newScreenFlattensSize() throws {
        #expect(try line(NewScreenRequest(
            workspace: WorkspaceHandle(rawValue: 6),
            size: CellSize(cols: 120, rows: 40)
        )) == envelope("new-screen", [
            "workspace": .number(6),
            "cols": .number(120),
            "rows": .number(40),
        ]))
    }
}

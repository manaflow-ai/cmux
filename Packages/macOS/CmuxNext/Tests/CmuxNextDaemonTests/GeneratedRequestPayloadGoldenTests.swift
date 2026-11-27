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

    @Test func creationRequestsFlattenTheirSharedOptions() throws {
        var tabOptions = baseOptions()
        tabOptions.terminalID = Self.terminalID
        tabOptions.shellArgs = ["-l"]
        #expect(try line(NewTabRequest(
            pane: PaneID(rawValue: 3),
            options: tabOptions,
            place: .string("after"),
            transaction: ClientTransactionID(rawValue: "tx-create")
        )) == envelope("new-tab", [
            "pane": .number(3),
            "place": .string("after"),
            "transaction": .string("tx-create"),
            "cwd": .string("/tmp"),
            "cols": .number(80),
            "rows": .number(24),
            "env": .object(["LANG": .string("C")]),
            "keep": .bool(true),
            "terminal_id": .string(Self.terminalID.rawValue),
            "shell_args": .array([.string("-l")]),
        ]))

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
            options: splitOptions,
            before: true,
            kind: .browser,
            url: "https://example.com"
        )) == envelope("split", [
            "pane": .number(3),
            "dir": .string("right"),
            "before": .bool(true),
            "kind": .string("browser"),
            "url": .string("https://example.com"),
            "cwd": .string("/tmp"),
            "cols": .number(80),
            "rows": .number(24),
            "env": .object(["LANG": .string("C")]),
            "keep": .bool(true),
            "terminal_id": .string(Self.terminalID.rawValue),
            "shell_args": .array([.string("-l")]),
            "pane_id": .string("pane-client-1"),
            "tab_id": .string("tab-client-1"),
            "split_id": .string("split-client-1"),
            "around": .number(9),
        ]))

        var columnOptions = baseOptions()
        columnOptions.paneID = "pane-client-2"
        columnOptions.tabID = "tab-client-2"
        #expect(try line(NewColumnRequest(
            pane: PaneID(rawValue: 3),
            width: 0.75,
            side: .left,
            options: columnOptions,
            kind: .pty
        )) == envelope("new-pane-right", [
            "pane": .number(3),
            "width": .number(0.75),
            "side": .string("left"),
            "kind": .string("pty"),
            "cwd": .string("/tmp"),
            "cols": .number(80),
            "rows": .number(24),
            "env": .object(["LANG": .string("C")]),
            "keep": .bool(true),
            "pane_id": .string("pane-client-2"),
            "tab_id": .string("tab-client-2"),
        ]))

        var rowOptions = baseOptions()
        rowOptions.paneID = "pane-client-3"
        rowOptions.tabID = "tab-client-3"
        #expect(try line(NewRowRequest(
            pane: PaneID(rawValue: 3),
            heightPermille: 400,
            options: rowOptions,
            transaction: ClientTransactionID(rawValue: "tx-row")
        )) == envelope("new-row", [
            "pane": .number(3),
            "height_permille": .number(400),
            "transaction": .string("tx-row"),
            "cwd": .string("/tmp"),
            "cols": .number(80),
            "rows": .number(24),
            "env": .object(["LANG": .string("C")]),
            "keep": .bool(true),
            "pane_id": .string("pane-client-3"),
            "tab_id": .string("tab-client-3"),
        ]))
    }

    @Test func closeRequestsEncodeOnlyEnabledOptions() throws {
        #expect(try line(CloseTabGroupRequest(group: TabGroupID("group-1"))) ==
            envelope("close-tab-group", ["group": .string("group-1")]))
        #expect(try line(ClosePaneRequest(pane: PaneID(rawValue: 3), endTerminals: true)) ==
            envelope("close-pane", ["pane": .number(3), "end_terminals": .bool(true)]))
        #expect(try line(CloseScreenRequest(screen: ScreenID(rawValue: 4))) ==
            envelope("close-screen", ["screen": .number(4)]))

        let mutation = MutationIdentity(origin: "golden-test", mutationID: "mutation-close", expectedRevision: 42)
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
            "expected_revision": .number(42),
        ]))
    }

    @Test func workspaceMutationsFlattenReferencesAndMutationKeys() throws {
        let mutation = MutationIdentity(origin: "golden-test", mutationID: "mutation-workspace", expectedRevision: 12)
        #expect(try line(RenameWorkspaceRequest(
            workspace: .key(Self.workspaceKey),
            name: "Build",
            source: .auto,
            expectedNameRevision: "11",
            release: true,
            mutation: mutation
        )) == envelope("rename-workspace", [
            "key": .string(Self.workspaceKey.rawValue),
            "name": .string("Build"),
            "source": .string("auto"),
            "expected_name_revision": .string("11"),
            "release": .bool(true),
            "origin": .string("golden-test"),
            "mutation_id": .string("mutation-workspace"),
            "expected_revision": .number(12),
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
            "expected_revision": .number(12),
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
            "report_closed_ids": .bool(true),
            "origin": .string("golden-test"),
            "mutation_id": .string("mutation-workspace"),
            "expected_revision": .number(12),
        ]))
    }

    @Test func newScreenFlattensSizeAndKeepsOptionalFieldsTopLevel() throws {
        #expect(try line(NewScreenRequest(
            workspace: WorkspaceHandle(rawValue: 6),
            size: CellSize(cols: 120, rows: 40),
            color: "blue",
            cwd: "/tmp",
            env: ["LANG": "C"],
            group: TabGroupID("group-2"),
            icon: "terminal",
            index: 3,
            pinned: true,
            screenName: "Build",
            shellArgs: ["-l"],
            terminalID: Self.terminalID
        )) == envelope("new-screen", [
            "workspace": .number(6),
            "cols": .number(120),
            "rows": .number(40),
            "color": .string("blue"),
            "cwd": .string("/tmp"),
            "env": .object(["LANG": .string("C")]),
            "group": .string("group-2"),
            "icon": .string("terminal"),
            "index": .number(3),
            "pinned": .bool(true),
            "screen_name": .string("Build"),
            "shell_args": .array([.string("-l")]),
            "terminal_id": .string(Self.terminalID.rawValue),
        ]))
    }
}

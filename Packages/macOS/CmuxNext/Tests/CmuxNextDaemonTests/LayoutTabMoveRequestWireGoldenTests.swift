import Foundation
import Testing
@testable import CmuxNextDaemon

/// The wire golden of every request in Sources/CmuxNextDaemon/Requests/Layout and Requests/TabMove:
/// the line each one sends today is recorded in
/// cmux-tui/spec/fixtures/layout-tab-move-requests/lines.json and compared here as JSON (key order does
/// not count). The migration to the generated `<Name>Request` types (CmuxNextWireGen RequestEmitter) must
/// keep these goldens green. The daemon side reads the same file (cmux-tui-core
/// server/tab_column_wire_tests.rs) and parses every line with the server's own `Request` parse.
///
/// Three fields hold caller-authored keys (WireKeyInventory.dictionaryFields): `new-row.env`,
/// `move-tab-to-split.respawn.env` and `move-tab-to-column.respawn.env`. Their goldens pin that the keys
/// go out as given (`FOO_BAR`, `camelKey`), so the generated coder must not rename them either.
struct LayoutTabMoveRequestWireGoldenTests {
    /// A request of the two directories, encoded the way `DaemonConnection` sends it.
    struct Encoded: Sendable {
        let type: String
        let encode: @Sendable () throws -> Data

        init<R: DaemonRequest>(_ request: R) {
            type = String(describing: R.self)
            encode = { try WireCoding.encodeRequest(request, id: 1) }
        }
    }

    private static let pane = PaneID(rawValue: 4)
    private static let surface = SurfaceID(rawValue: 7)
    private static let screen = ScreenID(rawValue: 2)
    private static let column = ColumnID(rawValue: 9)
    private static let transaction = ClientTransactionID(rawValue: "drag-1")
    /// Matches the schema's `terminal_id` pattern (UUIDv4 hex without dashes).
    private static let terminal = TerminalID(rawValue: "0123456789ab4cde8f0123456789abcd")
    private static let env = ["FOO_BAR": "1", "camelKey": "2"]
    private static let newTabPage = "cmux://newtab"

    /// Spawn options with the members `DaemonConnection` fills in (Placement, ShellIntegrationArguments).
    private static func placed(_ options: SpawnOptions) -> SpawnOptions {
        var options = options
        options.terminalID = terminal
        options.shellArgs = ["--login"]
        return options
    }

    /// The request each fixture entry records, by its `name`.
    static let requests: [String: Encoded] = [
        // Layout
        "set-split-ratio": Encoded(SetSplitRatioRequest(split: SplitID(rawValue: 5), ratio: 0.25)),
        "set-split-ratio in a drag transaction": Encoded(SetSplitRatioRequest(
            split: SplitID(rawValue: 5), ratio: 0.25, transaction: 41
        )),
        "set-viewport-pane-width": Encoded(SetColumnWidthRequest(pane: pane, width: 0.5)),
        "set-viewport-pane-width in a drag transaction": Encoded(SetColumnWidthRequest(
            pane: pane, width: 0.5, transaction: 42
        )),
        "undo-layout": Encoded(UndoLayoutRequest(pane: pane)),
        "undo-layout confirming a close": Encoded(UndoLayoutRequest(pane: pane, revision: 17, confirmClose: true)),
        "move-column left": Encoded(MoveColumnRequest(pane: pane, direction: .left)),
        "move-column right": Encoded(MoveColumnRequest(pane: pane, direction: .right)),
        "new-row": Encoded(NewRowRequest(pane: pane, height: 500)),
        // Every spawn field new-row has in the schema; `pane_id` and `tab_id` are `row-client-keys-v1`.
        "new-row with every spawn field": Encoded(NewRowRequest(pane: pane, height: 300, options: {
            var options = placed(SpawnOptions(cwd: "/tmp/w", size: CellSize(cols: 80, rows: 24), env: env, keep: true))
            options.paneID = "pane_a"
            options.tabID = "tab_a"
            return options
        }())),
        // `fit` is always sent, false included.
        "set-row-heights": Encoded(SetRowHeightsRequest(column: column, heights: [
            RowHeightValue(row: RowID(rawValue: 11), height: 400), RowHeightValue(row: RowID(rawValue: 12), height: 600),
        ])),
        "set-row-heights fitting in a drag transaction": Encoded(SetRowHeightsRequest(
            column: column, heights: [RowHeightValue(row: RowID(rawValue: 11), height: 1000)], fit: true, transaction: 43
        )),
        "set-column-dock undocking": Encoded(SetColumnDockRequest(pane: pane, dock: nil)),
        "set-column-dock docking": Encoded(SetColumnDockRequest(pane: pane, dock: DockSnapshot(edge: .left, mode: .docked))),
        "set-column-dock with every field": Encoded(SetColumnDockRequest(
            pane: pane, dock: DockSnapshot(edge: .right, mode: .overlay, role: .agentChat), pinned: true, transaction: 44
        )),
        "swap-pane by direction": Encoded(SwapPaneRequest(pane: pane, target: .direction(.up))),
        "swap-pane with a pane": Encoded(SwapPaneRequest(pane: pane, target: .pane(PaneID(rawValue: 6)))),
        "zoom-pane": Encoded(ZoomPaneRequest(pane: nil)),
        "zoom-pane with every field": Encoded(ZoomPaneRequest(pane: pane, mode: .on)),
        // TabMove
        "move-tab": Encoded(MoveTabRequest(surface: surface, pane: pane, index: 2)),
        "move-tab in a drag transaction": Encoded(MoveTabRequest(
            surface: surface, pane: pane, index: 0, transaction: transaction
        )),
        "move-tab-to-workspace into a new workspace": Encoded(MoveTabToWorkspaceRequest(surface: surface, workspace: nil)),
        "move-tab-to-workspace with every field": Encoded(MoveTabToWorkspaceRequest(
            surface: surface, workspace: WorkspaceHandle(rawValue: 3), transaction: transaction
        )),
        "move-tab-to-new-workspace": Encoded(MoveTabToNewWorkspaceRequest(surface: surface)),
        "move-tab-to-new-workspace with every field": Encoded(MoveTabToNewWorkspaceRequest(
            surface: surface, group: WorkspaceGroupID(rawValue: "grp_1"), index: 0, name: "Logs", transaction: transaction
        )),
        "move-tab-to-split": Encoded(MoveTabToSplitRequest(surface: surface, pane: pane, edge: .left)),
        "move-tab-to-split with every field": Encoded(MoveTabToSplitRequest(
            surface: surface, pane: pane, edge: .bottom, ratio: 0.25, transaction: transaction
        )),
        "move-tab-to-split keeping focus": Encoded(MoveTabToSplitKeepingFocusRequest(
            surface: surface, pane: pane, edge: .right
        )),
        "move-tab-to-split keeping focus with every field": Encoded(MoveTabToSplitKeepingFocusRequest(
            surface: surface, pane: pane, edge: .top, ratio: 0.5, transaction: transaction
        )),
        "move-tab-to-split respawning a terminal": Encoded(MoveTabToSplitRespawnRequest(
            surface: surface, pane: pane, edge: .right, respawn: .terminal(SpawnOptions())
        )),
        // Only cwd, env, terminal_id and shell_args of the spawn options reach a respawn.
        "move-tab-to-split respawning a terminal with every field": Encoded(MoveTabToSplitRespawnRequest(
            surface: surface, pane: pane, edge: .left, ratio: 0.5,
            respawn: .terminal(placed(SpawnOptions(cwd: "/tmp/w", env: env))), transaction: transaction
        )),
        "move-tab-to-split respawning a browser": Encoded(MoveTabToSplitRespawnRequest(
            surface: surface, pane: pane, edge: .right, respawn: .browser(url: newTabPage, engine: .webkit, profileID: nil)
        )),
        "move-tab-to-split respawning a browser with a profile": Encoded(MoveTabToSplitRespawnRequest(
            surface: surface, pane: pane, edge: .bottom, respawn: .browser(url: newTabPage, engine: .cef, profileID: "prof_1")
        )),
        "move-tab-to-column by screen": Encoded(MoveTabToColumnRequest(surface: surface, target: .screen(screen))),
        "move-tab-to-column by pane": Encoded(MoveTabToColumnRequest(surface: surface, target: .pane(pane))),
        // `pinned` is sent only for a pinned dock, `keep_focus` only when true.
        "move-tab-to-column into a dock": Encoded(MoveTabToColumnRequest(
            surface: surface, target: .screen(screen), dock: DockSnapshot(edge: .bottom, mode: .overlay)
        )),
        "move-tab-to-column with every field": Encoded(MoveTabToColumnRequest(
            surface: surface, target: .pane(pane), afterColumn: column, width: 0.5,
            dock: DockSnapshot(edge: .left, mode: .docked, role: .agentChat, isPinned: true), keepFocus: true,
            transaction: transaction
        )),
        "move-tab-to-column respawning a terminal": Encoded(MoveTabToColumnRespawnRequest(
            MoveTabToColumnRequest(
                surface: surface, target: .screen(screen), dock: DockSnapshot(edge: .right, mode: .docked, isPinned: true)
            ),
            respawn: .terminal(SpawnOptions(cwd: "/tmp/w"))
        )),
        "move-tab-to-column respawning a terminal with every field": Encoded(MoveTabToColumnRespawnRequest(
            MoveTabToColumnRequest(surface: surface, target: .pane(pane)),
            respawn: .terminal(placed(SpawnOptions(cwd: "/tmp/w", env: env)))
        )),
        "move-tab-to-column respawning a browser with every field": Encoded(MoveTabToColumnRespawnRequest(
            MoveTabToColumnRequest(
                surface: surface, target: .pane(pane), afterColumn: column, width: 0.5,
                dock: DockSnapshot(edge: .right, mode: .docked, role: .agentChat), keepFocus: true, transaction: transaction
            ),
            respawn: .browser(url: newTabPage, engine: .cef, profileID: "prof_1")
        )),
    ]

    @Test func sendsItsGoldenLines() throws {
        let recorded = try Self.fixture()
        #expect(Set(recorded.keys) == Set(Self.requests.keys), "fixture and test name different requests")
        for (name, golden) in recorded.sorted(by: { $0.key < $1.key }) {
            guard let request = Self.requests[name] else { continue }
            let line = try JSONDecoder().decode(JSONValue.self, from: request.encode())
            #expect(line == golden, "\(name)")
        }
    }

    /// Every request type of the two directories has a golden. Several types share a command
    /// (`move-tab-to-split` x3, `move-tab-to-column` x2), so coverage counts types, not commands.
    @Test func everyLayoutAndTabMoveRequestHasAGolden() {
        let covered = Set(Self.requests.values.map(\.type))
        let requestTypes: [any DaemonRequest.Type] = [
            SetSplitRatioRequest.self, SetColumnWidthRequest.self, UndoLayoutRequest.self, MoveColumnRequest.self,
            NewRowRequest.self, SetRowHeightsRequest.self, SetColumnDockRequest.self, SwapPaneRequest.self,
            ZoomPaneRequest.self, MoveTabRequest.self, MoveTabToWorkspaceRequest.self, MoveTabToNewWorkspaceRequest.self,
            MoveTabToSplitRequest.self, MoveTabToSplitKeepingFocusRequest.self, MoveTabToSplitRespawnRequest.self,
            MoveTabToColumnRequest.self, MoveTabToColumnRespawnRequest.self,
        ]
        let types = Set(requestTypes.map { String(describing: $0) })
        #expect(types.count == 17)
        #expect(types.subtracting(covered).isEmpty, "\(types.subtracting(covered).sorted())")
    }

    /// The keys a golden sends that sdk-schema.json does not declare. RequestEmitter generates a member for
    /// each declared field only, so each entry here is a byte the generated type would drop. The schema's
    /// `ColumnPin` lacks `pinned`, which the daemon reads (`ColumnDock.pinned`, `pinned-dock-alone-v1`):
    /// the schema gains it before `MoveTabToColumnRequest` moves, and this list empties.
    private static let undeclaredKeys: Set = ["move-tab-to-column.dock.pinned"]

    /// Every key a golden sends is a request field of its command in cmux-tui/spec/sdk-schema.json (nested
    /// objects against their `$.types` object, `heights[]` against `RowHeight`), every required field is
    /// sent, and the command is one the macOS app calls, so RequestEmitter generates a type with each of
    /// these members. Map values (`env`) hold caller-authored keys and are not walked.
    @Test func sendsSchemaFields() throws {
        let data = try Data(contentsOf: Self.repositoryRoot().appendingPathComponent("cmux-tui/spec/sdk-schema.json"))
        guard case .object(let schema) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let commands)? = schema["commands"], case .object(let types)? = schema["types"] else {
            Issue.record("sdk-schema.json has no commands or types")
            return
        }
        var walk = SchemaWalk(types: types)
        for (name, golden) in try Self.fixture() {
            guard case .object(var line) = golden, case .string(let command)? = line["cmd"],
                  case .object(let entry)? = commands[command],
                  case .array(let clients)? = entry["clients"], clients.contains(JSONValue.string("macos")) else {
                Issue.record("\(name): not a macos command of sdk-schema.json")
                continue
            }
            line["id"] = nil
            line["cmd"] = nil
            var fields: [String: JSONValue] = [:]
            if case .object(let request)? = entry["request"], case .object(let declared)? = request["fields"] {
                fields = declared
            }
            walk.check(command, line, fields)
        }
        #expect(walk.undeclared == Self.undeclaredKeys)
        #expect(walk.missing.isEmpty, "required fields not sent: \(walk.missing.sorted())")
    }

    /// Checks one encoded object against the schema fields of its type.
    struct SchemaWalk {
        let types: [String: JSONValue]
        var undeclared: Set<String> = []
        var missing: Set<String> = []

        mutating func check(_ path: String, _ value: [String: JSONValue], _ fields: [String: JSONValue]) {
            for key in value.keys where fields[key] == nil { undeclared.insert("\(path).\(key)") }
            for (key, spec) in fields where value[key] == nil {
                if case .object(let field) = spec, field["presence"] == JSONValue.string("required") {
                    missing.insert("\(path).\(key)")
                }
            }
            for (key, item) in value {
                guard case .object(let field)? = fields[key], case .object(let type)? = field["type"] else { continue }
                if type["kind"] == JSONValue.string("array"), case .object(let items)? = type["items"],
                   case .array(let elements) = item {
                    guard let nested = objectFields(items) else { continue }
                    for case .object(let element) in elements { check("\(path).\(key)", element, nested) }
                } else if let nested = objectFields(type), case .object(let object) = item {
                    check("\(path).\(key)", object, nested)
                }
            }
        }

        /// The fields of `type` when it names an object type of `$.types`.
        private func objectFields(_ type: [String: JSONValue]) -> [String: JSONValue]? {
            guard type["kind"] == JSONValue.string("ref"), case .string(let name)? = type["name"],
                  case .object(let target)? = types[name], target["kind"] == JSONValue.string("object") else { return nil }
            guard case .object(let fields)? = target["fields"] else { return [:] }
            return fields
        }
    }

    // Fixture ---------------------------------------------------------------

    /// `name -> line` of lines.json.
    private static func fixture() throws -> [String: JSONValue] {
        let data = try Data(contentsOf: repositoryRoot().appendingPathComponent(
            "cmux-tui/spec/fixtures/layout-tab-move-requests/lines.json"
        ))
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let entries)? = root["requests"] else { return [:] }
        var lines: [String: JSONValue] = [:]
        for case .object(let entry) in entries {
            guard case .string(let name)? = entry["name"], let line = entry["line"] else { continue }
            #expect(lines.updateValue(line, forKey: name) == nil, "\(name) twice")
        }
        return lines
    }

    private static func repositoryRoot() throws -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no cmux-tui/spec above \(#filePath)")
            root = parent
        }
        return root
    }
}

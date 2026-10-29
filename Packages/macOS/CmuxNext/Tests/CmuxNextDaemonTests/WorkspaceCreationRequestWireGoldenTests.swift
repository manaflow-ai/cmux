import Foundation
import Testing
@testable import CmuxNextDaemon

/// The wire golden of every request in Sources/CmuxNextDaemon/Requests/Workspace and
/// Requests/Creation: the line each one sends today, compared as JSON (key order does
/// not count). The migration to the generated `<Name>Request` types (CmuxNextWireGen RequestEmitter)
/// must send the same lines, with the ids the client mints (workspace key, terminal id, pane, tab
/// and split ids, mutation id) passed through as given.
///
/// Dictionary-valued fields (WireKeyInventory.dictionaryFields) here: `env` of create-terminal,
/// new-tab, split, new-pane and new-pane-right. The hand-written types hold a `[String: String]`
/// there, which the snake-case strategy does not rename, so its keys go as given in both coders.
///
/// One listed byte change: SpawnOptions sends `argv`, `command` and `name` to new-tab, split,
/// new-pane and new-pane-right, which have no such fields in the schema (only create-terminal has
/// them). The daemon's `Command` enum does not deny unknown fields and drops them; the generated
/// types have no member for them, so those keys leave the line (`outsideSchema` names them).
struct WorkspaceCreationRequestWireGoldenTests {
    private static let mutation = MutationIdentity(
        origin: "app", mutationID: "m-1", expectedGeneration: DaemonGeneration(rawValue: "gen-1"), expectedRevision: 9
    )
    private static let mutationFields: [String: JSONValue] = [
        "origin": .string("app"), "mutation_id": .string("m-1"), "expected_generation": .string("gen-1"),
        "expected_revision": .number(9),
    ]
    private static let byKey = WorkspaceRef.key(WorkspaceKey(rawValue: "ws-1"))
    private static let byHandle = WorkspaceRef.handle(WorkspaceHandle(rawValue: 3))
    /// Caller-authored keys: upper snake and camel case, neither renamed.
    private static let env = ["CMUX_WORKSPACE_ID": "ws-1", "lowerCamel": "x"]
    private static let envField = JSONValue.object(["CMUX_WORKSPACE_ID": .string("ws-1"), "lowerCamel": .string("x")])

    /// One request's expected line, `id` and `cmd` included. `outsideSchema` names the sent keys
    /// that are not request fields of the command in the schema (the listed byte change).
    struct Golden: Sendable, CustomTestStringConvertible {
        let name: String
        let encode: @Sendable () throws -> Data
        let command: String
        let fields: [String: JSONValue]
        let outsideSchema: Set<String>

        init<R: DaemonRequest>(_ name: String, _ request: R, _ fields: [String: JSONValue],
                               outsideSchema: Set<String> = []) {
            self.name = name
            encode = { try WireCoding.encodeRequest(request, id: 1) }
            command = R.command
            var line = fields
            line["id"] = .number(1)
            line["cmd"] = .string(R.command)
            self.fields = line
            self.outsideSchema = outsideSchema
        }

        var testDescription: String { name }
    }

    /// Every spawn option the schema serves on new-tab, split, new-pane and new-pane-right, with
    /// the client-minted terminal, pane, tab and split ids.
    private static func spawnOptions(splitID: String? = nil) -> SpawnOptions {
        var options = SpawnOptions(cwd: "/tmp", size: CellSize(cols: 80, rows: 24), env: env,
                                   workspace: WorkspaceKey(rawValue: "ws-1"), keep: true)
        options.terminalID = TerminalID(rawValue: "term-1")
        options.shellArgs = ["--login"]
        options.paneID = "pane_c1"
        options.tabID = "tab_c1"
        options.splitID = splitID
        return options
    }

    /// `spawnOptions()`'s line; `workspace` is never sent.
    private static func spawnFields(paneAndTab: Bool) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "cwd": .string("/tmp"), "cols": .number(80), "rows": .number(24), "env": envField, "keep": .bool(true),
            "terminal_id": .string("term-1"), "shell_args": .array([.string("--login")]),
        ]
        if paneAndTab {
            fields["pane_id"] = .string("pane_c1")
            fields["tab_id"] = .string("tab_c1")
        }
        return fields
    }

    private static func merged(_ parts: [String: JSONValue]...) -> [String: JSONValue] {
        parts.reduce(into: [:]) { line, part in line.merge(part) { _, new in new } }
    }

    static let workspaceGoldens: [Golden] = [
        Golden("close-workspace", CloseWorkspaceRequest(workspace: byKey, mutation: nil), ["key": .string("ws-1")]),
        // `reason` goes out only with `end_terminals`.
        Golden("close-workspace reason without end_terminals",
               CloseWorkspaceRequest(workspace: byKey, reason: .sessionEnd, mutation: nil), ["key": .string("ws-1")]),
        Golden("close-workspace with every field",
               CloseWorkspaceRequest(workspace: byHandle, endTerminals: true, reason: .sessionEnd, ifEmpty: true,
                                     mutation: mutation),
               merged(["workspace": .number(3), "end_terminals": .bool(true), "reason": .string("session_end"),
                       "if_empty": .bool(true)], mutationFields)),
        Golden("put-blob", PutBlobRequest(mediaType: "image/png", data: Data([1, 2, 3])),
               ["media_type": .string("image/png"), "data": .string("AQID")]),
        Golden("get-blob", GetBlobRequest(blob: "blob:sha256-ab"), ["blob": .string("blob:sha256-ab")]),
        Golden("create-workspace", CreateWorkspaceRequest(mutation: nil), [:]),
        // The workspace key and the mutation id are minted by the client.
        Golden("create-workspace with every field",
               CreateWorkspaceRequest(name: "Docs", key: WorkspaceKey(rawValue: "ws-new"), mutation: mutation),
               merged(["name": .string("Docs"), "key": .string("ws-new")], mutationFields)),
        Golden("rename-workspace", RenameWorkspaceRequest(workspace: byKey, name: "N", mutation: nil),
               ["key": .string("ws-1"), "name": .string("N")]),
        // `expected_name_revision` is a decimal string; `release` goes out only when true.
        Golden("rename-workspace with every field",
               RenameWorkspaceRequest(workspace: byHandle, name: "N", source: .auto, expectedNameRevision: 42,
                                      release: true, mutation: mutation),
               merged(["workspace": .number(3), "name": .string("N"), "source": .string("auto"),
                       "expected_name_revision": .string("42"), "release": .bool(true)], mutationFields)),
        Golden("move-workspace", MoveWorkspaceRequest(workspace: byKey, index: 0, mutation: nil),
               ["key": .string("ws-1"), "index": .number(0)]),
        Golden("move-workspace with every field", MoveWorkspaceRequest(workspace: byHandle, index: 2, mutation: mutation),
               merged(["workspace": .number(3), "index": .number(2)], mutationFields)),
        Golden("set-workspace-metadata", SetWorkspaceMetadataRequest(workspace: byKey, mutation: nil),
               ["key": .string("ws-1")]),
        Golden("set-workspace-metadata with every field",
               SetWorkspaceMetadataRequest(workspace: byHandle, color: .set("blue"), icon: .set("star"),
                                           title: .set("T"), pinned: true, markedUnread: false, mutation: mutation),
               merged(["workspace": .number(3), "color": .string("blue"), "icon": .string("star"),
                       "title": .string("T"), "pinned": .bool(true), "marked_unread": .bool(false)], mutationFields)),
        // `.clear` sends an explicit null.
        Golden("set-workspace-metadata clearing color, icon and title",
               SetWorkspaceMetadataRequest(workspace: byKey, color: .clear, icon: .clear, title: .clear, mutation: nil),
               ["key": .string("ws-1"), "color": .null, "icon": .null, "title": .null]),
    ]

    static let creationGoldens: [Golden] = [
        Golden("create-terminal", CreateTerminalRequest(workspace: byKey, mutation: nil), ["key": .string("ws-1")]),
        Golden("create-terminal with every field", { () -> CreateTerminalRequest in
            var request = CreateTerminalRequest(
                workspace: byHandle, argv: ["/bin/zsh", "-l"], command: "make", cwd: "/tmp", name: "build",
                size: CellSize(cols: 80, rows: 24), terminalID: TerminalID(rawValue: "term-1"), env: env, keep: true,
                mutation: mutation)
            request.shellArgs = ["--login"]
            return request
        }(), merged(["workspace": .number(3), "argv": .array([.string("/bin/zsh"), .string("-l")]),
                     "command": .string("make"), "cwd": .string("/tmp"), "name": .string("build"), "cols": .number(80),
                     "rows": .number(24), "terminal_id": .string("term-1"), "env": envField, "keep": .bool(true),
                     "shell_args": .array([.string("--login")])], mutationFields)),
        // `keep: false` is sent when given (the daemon default is the same).
        Golden("create-terminal keep false", CreateTerminalRequest(workspace: byKey, keep: false, mutation: nil),
               ["key": .string("ws-1"), "keep": .bool(false)]),
        Golden("new-tab", NewTabRequest(pane: nil), [:]),
        // new-tab has no client pane or tab id in the schema; only its terminal id is minted.
        Golden("new-tab with every field", NewTabRequest(pane: PaneID(rawValue: 7), options: { () -> SpawnOptions in
            var options = spawnOptions()
            options.paneID = nil
            options.tabID = nil
            return options
        }()), merged(["pane": .number(7)], spawnFields(paneAndTab: false))),
        Golden("new-tab with create-terminal's options",
               NewTabRequest(pane: PaneID(rawValue: 7), options: SpawnOptions(argv: ["/bin/sh"], command: "ls", name: "n")),
               ["pane": .number(7), "argv": .array([.string("/bin/sh")]), "command": .string("ls"), "name": .string("n")],
               outsideSchema: ["argv", "command", "name"]),
        Golden("new-screen", NewScreenRequest(workspace: nil), [:]),
        Golden("new-screen with every field",
               NewScreenRequest(workspace: WorkspaceHandle(rawValue: 3), size: CellSize(cols: 80, rows: 24)),
               ["workspace": .number(3), "cols": .number(80), "rows": .number(24)]),
        Golden("split", SplitRequest(pane: PaneID(rawValue: 7), direction: .down),
               ["pane": .number(7), "dir": .string("down")]),
        // `tab` is not sent: moving an existing tab is move-tab-to-split.
        Golden("split with every field",
               SplitRequest(pane: PaneID(rawValue: 7), direction: .right, tab: SurfaceID(rawValue: 5),
                            options: spawnOptions(splitID: "split_c1")),
               merged(["pane": .number(7), "dir": .string("right"), "split_id": .string("split_c1")],
                      spawnFields(paneAndTab: true))),
        Golden("split with create-terminal's options",
               SplitRequest(pane: PaneID(rawValue: 7), direction: .right, options: SpawnOptions(command: "ls", name: "n")),
               ["pane": .number(7), "dir": .string("right"), "command": .string("ls"), "name": .string("n")],
               outsideSchema: ["command", "name"]),
        Golden("new-pane", NewPaneRequest(pane: PaneID(rawValue: 7)), ["pane": .number(7)]),
        Golden("new-pane with every field", NewPaneRequest(pane: PaneID(rawValue: 7), options: spawnOptions()),
               merged(["pane": .number(7)], spawnFields(paneAndTab: true))),
        Golden("new-pane-right", NewColumnRequest(pane: PaneID(rawValue: 7)), ["pane": .number(7)]),
        // `width` is float32 in the schema; 0.5 is exact in a Float.
        Golden("new-pane-right with every field",
               NewColumnRequest(pane: PaneID(rawValue: 7), width: 0.5, options: spawnOptions()),
               merged(["pane": .number(7), "width": .number(0.5)], spawnFields(paneAndTab: true))),
    ]

    static let goldens = workspaceGoldens + creationGoldens

    @Test(arguments: goldens)
    func sendsItsGoldenLine(_ golden: Golden) throws {
        let line = try JSONDecoder().decode(JSONValue.self, from: golden.encode())
        #expect(line == .object(golden.fields))
    }

    /// Every key a golden sends is a request field of its command in cmux-tui/spec/sdk-schema.json
    /// or listed in `outsideSchema`, every required field is sent, and the command is one the macOS
    /// app calls, so RequestEmitter generates a type with these members.
    @Test func sendsSchemaFields() throws {
        let commands = try Self.schemaCommands()
        for golden in Self.goldens {
            let fields = try Self.requestFields(golden.command, in: commands)
            let sent = Set(golden.fields.keys).subtracting(["id", "cmd"])
            let extra = sent.subtracting(fields.keys).subtracting(golden.outsideSchema)
            #expect(extra.isEmpty, "\(golden.name): not schema fields of \(golden.command): \(extra.sorted())")
            #expect(golden.outsideSchema.isSubset(of: sent), "\(golden.name): outsideSchema keys not sent")
            #expect(golden.outsideSchema.isDisjoint(with: fields.keys), "\(golden.name): outsideSchema keys are fields")
            let required = fields.compactMap { entry -> String? in
                guard case .object(let spec) = entry.value, spec["presence"] == JSONValue.string("required") else {
                    return nil
                }
                return entry.key
            }
            let missing = Set(required).subtracting(sent)
            #expect(missing.isEmpty, "\(golden.name): required fields of \(golden.command) not sent: \(missing.sorted())")
        }
    }

    /// The ids the client mints before the daemon answers are string request fields of their
    /// commands, so a generated type carries the caller's value as given and mints none itself.
    @Test func clientMintedIDsAreStringFields() throws {
        let minted: [String: [String]] = [
            "create-workspace": ["key", "mutation_id"],
            "create-terminal": ["terminal_id", "mutation_id"],
            "new-tab": ["terminal_id"],
            "split": ["terminal_id", "pane_id", "tab_id", "split_id"],
            "new-pane": ["terminal_id", "pane_id", "tab_id"],
            "new-pane-right": ["terminal_id", "pane_id", "tab_id"],
        ]
        let commands = try Self.schemaCommands()
        for (command, names) in minted {
            let fields = try Self.requestFields(command, in: commands)
            for name in names {
                guard case .object(let spec)? = fields[name], case .object(let type)? = spec["type"] else {
                    Issue.record("\(command).\(name) is not a request field")
                    continue
                }
                #expect(type["kind"] == JSONValue.string("scalar") && type["name"] == JSONValue.string("string"),
                        "\(command).\(name)")
            }
        }
    }

    /// `SpawnOptions.drop` keeps the client-minted ids for a daemon that serves them and removes
    /// them, and only them, for one that does not.
    @Test func dropRemovesOnlyUnservedClientIDs() throws {
        var kept = Self.spawnOptions(splitID: "split_c1")
        kept.drop(callerTerminal: false, clientKeys: false, clientSplitID: false)
        #expect(kept == Self.spawnOptions(splitID: "split_c1"))

        var dropped = Self.spawnOptions(splitID: "split_c1")
        dropped.drop(callerTerminal: true, clientKeys: true, clientSplitID: true)
        let line = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(
            SplitRequest(pane: PaneID(rawValue: 7), direction: .right, options: dropped), id: 1))
        var expected = Self.spawnFields(paneAndTab: false)
        expected["terminal_id"] = nil
        #expect(line == .object(Self.merged(["id": .number(1), "cmd": .string("split"), "pane": .number(7),
                                             "dir": .string("right")], expected)))
    }

    /// Every request type of the two directories has a golden.
    @Test func everyWorkspaceAndCreationCommandHasAGolden() {
        let covered = Set(Self.goldens.map(\.command))
        let commands: Set = [
            CloseWorkspaceRequest.command, PutBlobRequest.command, GetBlobRequest.command,
            CreateWorkspaceRequest.command, RenameWorkspaceRequest.command, MoveWorkspaceRequest.command,
            SetWorkspaceMetadataRequest.command, CreateTerminalRequest.command, NewTabRequest.command,
            NewScreenRequest.command, SplitRequest.command, NewPaneRequest.command, NewColumnRequest.command,
        ]
        #expect(commands.count == 13)
        #expect(commands.subtracting(covered).isEmpty)
    }

    /// The request fields of `command`, which must be a macos command of the schema.
    private static func requestFields(_ command: String, in commands: [String: JSONValue]) throws -> [String: JSONValue] {
        guard case .object(let spec)? = commands[command] else { throw SchemaShapeError.missing(command) }
        guard case .array(let clients)? = spec["clients"], clients.contains(.string("macos")) else {
            throw SchemaShapeError.notMacOS(command)
        }
        guard case .object(let request)? = spec["request"], case .object(let fields)? = request["fields"] else {
            return [:]
        }
        return fields
    }

    enum SchemaShapeError: Error {
        case missing(String)
        case notMacOS(String)
        case noSchema
    }

    /// `$.commands` of cmux-tui/spec/sdk-schema.json.
    private static func schemaCommands() throws -> [String: JSONValue] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { throw SchemaShapeError.noSchema }
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/sdk-schema.json"))
        guard case .object(let schema) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let commands)? = schema["commands"] else { throw SchemaShapeError.noSchema }
        return commands
    }
}

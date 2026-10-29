import Foundation
import Testing
@testable import CmuxNextDaemon

/// The wire golden of every request in Sources/CmuxNextDaemon/Requests/Screens: the
/// line each one sends today, compared as JSON (key order does not count). The migration to the
/// generated `<Name>Request` types (CmuxNextWireGen RequestEmitter) must send the same lines; the
/// generated coder writes each member under its schema wire name, so a golden that holds here and
/// after the migration proves the bytes did not change.
///
/// One field of this directory holds caller-authored keys (WireKeyInventory.dictionaryFields):
/// `new-screen.env`, a map whose keys the snake-case strategy leaves alone. Its golden pins that the
/// keys go out as given. `new-screen` is flat on the wire: `ScreenSpec` and `SpawnOptions` are the
/// app's groupings of the schema's top-level members (`screen_name`, `cols`, `rows`, ...).
struct ScreensRequestWireGoldenTests {
    private static let group = ScreenGroupID(rawValue: "sgrp_1")
    private static let saved = SavedScreenGroupID(rawValue: "ssg_1")
    private static let workspace = WorkspaceHandle(rawValue: 3)
    /// Matches the schema's `terminal_id` pattern (UUIDv4 hex without dashes).
    private static let terminal = TerminalID(rawValue: "0123456789ab4cde8f0123456789abcd")

    /// One request's expected line, `id` and `cmd` included.
    struct Golden: Sendable, CustomTestStringConvertible {
        let name: String
        let encode: @Sendable () throws -> Data
        let command: String
        let fields: [String: JSONValue]

        init<R: DaemonRequest>(_ name: String, _ request: R, _ fields: [String: JSONValue]) {
            self.name = name
            encode = { try WireCoding.encodeRequest(request, id: 1) }
            command = R.command
            var line = fields
            line["id"] = .number(1)
            line["cmd"] = .string(R.command)
            self.fields = line
        }

        var testDescription: String { name }
    }

    static let goldens: [Golden] = [
        // new-screen: an empty spec and default options send nothing but the envelope.
        Golden("new-screen", NewScreenWithSpecRequest(workspace: nil, spec: ScreenSpec()), [:]),
        // The spec's `name` goes out as `screen_name`, the schema name.
        Golden("new-screen with every spec field",
               NewScreenWithSpecRequest(workspace: workspace,
                                        spec: ScreenSpec(name: "Logs", color: "blue", icon: "star", pinned: true,
                                                         index: 2, group: group)),
               ["workspace": .number(3), "screen_name": .string("Logs"), "color": .string("blue"),
                "icon": .string("star"), "pinned": .bool(true), "index": .number(2), "group": .string("sgrp_1")]),
        // `env` is a map: its keys go out as given, never snake-cased. `terminal_id` and `shell_args`
        // are the members DaemonConnection sets (Placement, ShellIntegrationArguments).
        Golden("new-screen with every spawn field", {
            var options = SpawnOptions(cwd: "/tmp/w", size: CellSize(cols: 80, rows: 24),
                                       env: ["FOO_BAR": "1", "camelKey": "2"])
            options.terminalID = terminal
            options.shellArgs = ["--login"]
            return NewScreenWithSpecRequest(workspace: workspace, spec: ScreenSpec(), options: options)
        }(), [
            "workspace": .number(3), "cwd": .string("/tmp/w"), "cols": .number(80), "rows": .number(24),
            "env": .object(["FOO_BAR": .string("1"), "camelKey": .string("2")]),
            "terminal_id": .string("0123456789ab4cde8f0123456789abcd"), "shell_args": .array([.string("--login")]),
        ]),
        Golden("delete-saved-screen-group", DeleteSavedScreenGroupRequest(saved: saved), ["saved": .string("ssg_1")]),
        Golden("reopen-saved-screen-group", ReopenSavedScreenGroupRequest(saved: saved, workspace: workspace),
               ["saved": .string("ssg_1"), "workspace": .number(3)]),
        Golden("save-screen-group", SaveScreenGroupRequest(group: group), ["group": .string("sgrp_1")]),
        Golden("unsave-screen-group", UnsaveScreenGroupRequest(group: group), ["group": .string("sgrp_1")]),
        Golden("list-saved-screen-groups", ListSavedScreenGroupsRequest(), [:]),
        Golden("ungroup-screen-group", UngroupScreenGroupRequest(group: group), ["group": .string("sgrp_1")]),
        // `end_terminals` is sent whenever the caller sets it, false included (the schema default is false).
        Golden("close-screen-group", CloseScreenGroupRequest(group: group), ["group": .string("sgrp_1")]),
        Golden("close-screen-group ending terminals", CloseScreenGroupRequest(group: group, endTerminals: true),
               ["group": .string("sgrp_1"), "end_terminals": .bool(true)]),
        Golden("close-screen-group keeping terminals", CloseScreenGroupRequest(group: group, endTerminals: false),
               ["group": .string("sgrp_1"), "end_terminals": .bool(false)]),
        Golden("add-screens-to-screen-group",
               AddScreensToScreenGroupRequest(group: group, screens: [ScreenID(rawValue: 1), ScreenID(rawValue: 2)]),
               ["group": .string("sgrp_1"), "screens": .array([.number(1), .number(2)])]),
        Golden("add-screens-to-screen-group with every field",
               AddScreensToScreenGroupRequest(group: group, screens: [ScreenID(rawValue: 1)], index: 0),
               ["group": .string("sgrp_1"), "screens": .array([.number(1)]), "index": .number(0)]),
        Golden("remove-screens-from-screen-group",
               RemoveScreensFromScreenGroupRequest(screens: [ScreenID(rawValue: 4)]),
               ["screens": .array([.number(4)])]),
        Golden("move-screen-group", MoveScreenGroupRequest(group: group), ["group": .string("sgrp_1")]),
        Golden("move-screen-group to an index", MoveScreenGroupRequest(group: group, index: 1),
               ["group": .string("sgrp_1"), "index": .number(1)]),
        Golden("move-screen-group into a workspace",
               MoveScreenGroupRequest(group: group, index: 0, workspace: workspace),
               ["group": .string("sgrp_1"), "index": .number(0), "workspace": .number(3)]),
        Golden("move-screen-group into a new workspace", MoveScreenGroupRequest(group: group, newWorkspace: true),
               ["group": .string("sgrp_1"), "new_workspace": .bool(true)]),
        Golden("create-screen-group", CreateScreenGroupRequest(screens: [ScreenID(rawValue: 1), ScreenID(rawValue: 2)]),
               ["screens": .array([.number(1), .number(2)])]),
        Golden("create-screen-group with every field",
               CreateScreenGroupRequest(screens: [ScreenID(rawValue: 1)], name: "Build", color: "green"),
               ["screens": .array([.number(1)]), "name": .string("Build"), "color": .string("green")]),
        Golden("update-screen-group", UpdateScreenGroupRequest(group: group), ["group": .string("sgrp_1")]),
        Golden("update-screen-group with every field",
               UpdateScreenGroupRequest(group: group, name: "N", color: "red", collapsed: true, icon: .set("star")),
               ["group": .string("sgrp_1"), "name": .string("N"), "color": .string("red"), "collapsed": .bool(true),
                "icon": .string("star")]),
        // `.clear` sends an explicit null, which removes the icon.
        Golden("update-screen-group clearing icon",
               UpdateScreenGroupRequest(group: group, collapsed: false, icon: .clear),
               ["group": .string("sgrp_1"), "collapsed": .bool(false), "icon": .null]),
        Golden("set-screen-metadata", SetScreenMetadataRequest(screen: ScreenID(rawValue: 5)), ["screen": .number(5)]),
        Golden("set-screen-metadata with every field",
               SetScreenMetadataRequest(screen: ScreenID(rawValue: 5), color: .set("#FF8800"), icon: .set("star")),
               ["screen": .number(5), "color": .string("#FF8800"), "icon": .string("star")]),
        // A null clears the field; an omitted one keeps it.
        Golden("set-screen-metadata clearing color and icon",
               SetScreenMetadataRequest(screen: ScreenID(rawValue: 5), color: .clear, icon: .clear),
               ["screen": .number(5), "color": .null, "icon": .null]),
        Golden("set-screen-pinned", SetScreenPinnedRequest(screen: ScreenID(rawValue: 5), pinned: true),
               ["screen": .number(5), "pinned": .bool(true)]),
        Golden("set-screen-pinned unpinning", SetScreenPinnedRequest(screen: ScreenID(rawValue: 5), pinned: false),
               ["screen": .number(5), "pinned": .bool(false)]),
        Golden("move-screen", MoveScreenRequest(screen: ScreenID(rawValue: 5)), ["screen": .number(5)]),
        Golden("move-screen into a workspace",
               MoveScreenRequest(screen: ScreenID(rawValue: 5), index: 0, workspace: workspace),
               ["screen": .number(5), "index": .number(0), "workspace": .number(3)]),
        Golden("move-screen into a new workspace", MoveScreenRequest(screen: ScreenID(rawValue: 5), newWorkspace: true),
               ["screen": .number(5), "new_workspace": .bool(true)]),
    ]

    @Test(arguments: goldens)
    func sendsItsGoldenLine(_ golden: Golden) throws {
        let line = try JSONDecoder().decode(JSONValue.self, from: golden.encode())
        #expect(line == .object(golden.fields))
    }

    /// Every key a golden sends is a request field of its command in cmux-tui/spec/sdk-schema.json, every
    /// required field is sent, and the command is one the macOS app calls, so RequestEmitter generates a
    /// type with each of these members.
    @Test func sendsSchemaFields() throws {
        let commands = try Self.schemaCommands()
        for golden in Self.goldens {
            guard case .object(let command)? = commands[golden.command] else {
                Issue.record("\(golden.command) is not in sdk-schema.json")
                continue
            }
            guard case .array(let clients)? = command["clients"], clients.contains(.string("macos")) else {
                Issue.record("\(golden.command) is not a macos command")
                continue
            }
            let fields: [String: JSONValue]
            if case .object(let request)? = command["request"], case .object(let declared)? = request["fields"] {
                fields = declared
            } else {
                fields = [:]
            }
            let sent = Set(golden.fields.keys).subtracting(["id", "cmd"])
            let extra = sent.subtracting(fields.keys)
            #expect(extra.isEmpty, "\(golden.name): not schema fields of \(golden.command): \(extra.sorted())")
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

    /// Every request type of the directory has a golden.
    @Test func everyScreensCommandHasAGolden() {
        let covered = Set(Self.goldens.map(\.command))
        let commands: Set = [
            NewScreenWithSpecRequest.command, DeleteSavedScreenGroupRequest.command,
            ReopenSavedScreenGroupRequest.command, SaveScreenGroupRequest.command, UnsaveScreenGroupRequest.command,
            ListSavedScreenGroupsRequest.command, UngroupScreenGroupRequest.command, CloseScreenGroupRequest.command,
            AddScreensToScreenGroupRequest.command, RemoveScreensFromScreenGroupRequest.command,
            MoveScreenGroupRequest.command, CreateScreenGroupRequest.command, UpdateScreenGroupRequest.command,
            SetScreenMetadataRequest.command, SetScreenPinnedRequest.command, MoveScreenRequest.command,
        ]
        #expect(commands.count == 16)
        #expect(commands.subtracting(covered).isEmpty)
    }

    /// `$.commands` of cmux-tui/spec/sdk-schema.json.
    private static func schemaCommands() throws -> [String: JSONValue] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no cmux-tui/spec above \(#filePath)")
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/sdk-schema.json"))
        guard case .object(let schema) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let commands)? = schema["commands"] else { return [:] }
        return commands
    }
}

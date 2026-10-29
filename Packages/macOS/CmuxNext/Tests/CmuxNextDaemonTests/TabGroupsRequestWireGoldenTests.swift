import Foundation
import Testing
@testable import CmuxNextDaemon

/// The wire golden of every request in Sources/CmuxNextDaemon/Requests/TabGroups: the
/// line each one sends today, compared as JSON (key order does not count). The migration to the
/// generated `<Name>Request` types (CmuxNextWireGen RequestEmitter) must send the same lines; the
/// generated coder writes each member under its schema wire name, so a golden that holds here and
/// after the migration proves the bytes did not change.
///
/// No request of this directory has a dictionary-valued field (WireKeyInventory.dictionaryFields):
/// every value is a scalar, an id or an array of ids, so no byte may change. `ratio` and `width`
/// are `float32` in the schema; the goldens use values a Float holds exactly.
struct TabGroupsRequestWireGoldenTests {
    private static let group = TabGroupID(rawValue: "tgrp_1")
    private static let transaction = ClientTransactionID(rawValue: "tx-1")

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
        Golden("list-tab-groups", ListTabGroupsRequest(), [:]),
        // `tabs` goes out as `surfaces`, the schema name (`tabs` is only its alias).
        Golden("create-tab-group", CreateTabGroupRequest(tabs: [SurfaceID(rawValue: 1), SurfaceID(rawValue: 2)]),
               ["surfaces": .array([.number(1), .number(2)])]),
        Golden("create-tab-group with every field",
               CreateTabGroupRequest(tabs: [SurfaceID(rawValue: 1)], group: group, name: "Docs", color: "blue",
                                     transaction: transaction),
               ["surfaces": .array([.number(1)]), "group": .string("tgrp_1"), "name": .string("Docs"),
                "color": .string("blue"), "transaction": .string("tx-1")]),
        Golden("update-tab-group", UpdateTabGroupRequest(group: group), ["group": .string("tgrp_1")]),
        Golden("update-tab-group with every field",
               UpdateTabGroupRequest(group: group, name: "N", color: .set("red"), collapsed: true, icon: .set("star")),
               ["group": .string("tgrp_1"), "name": .string("N"), "color": .string("red"), "collapsed": .bool(true),
                "icon": .string("star")]),
        // `.clear` sends an explicit null: unchanged for `color`, removed for `icon`.
        Golden("update-tab-group clearing color and icon",
               UpdateTabGroupRequest(group: group, color: .clear, collapsed: false, icon: .clear),
               ["group": .string("tgrp_1"), "color": .null, "collapsed": .bool(false), "icon": .null]),
        Golden("ungroup-tab-group", UngroupTabGroupRequest(group: group), ["group": .string("tgrp_1")]),
        // `end_terminals` is sent only when true (the schema default is false).
        Golden("close-tab-group", CloseTabGroupRequest(group: group), ["group": .string("tgrp_1")]),
        Golden("close-tab-group ending terminals", CloseTabGroupRequest(group: group, endTerminals: true),
               ["group": .string("tgrp_1"), "end_terminals": .bool(true)]),
        Golden("add-tabs-to-tab-group", AddTabsToGroupRequest(group: group, tabs: [SurfaceID(rawValue: 3)]),
               ["group": .string("tgrp_1"), "surfaces": .array([.number(3)])]),
        Golden("add-tabs-to-tab-group with every field",
               AddTabsToGroupRequest(group: group, tabs: [SurfaceID(rawValue: 3), SurfaceID(rawValue: 4)],
                                     transaction: transaction),
               ["group": .string("tgrp_1"), "surfaces": .array([.number(3), .number(4)]),
                "transaction": .string("tx-1")]),
        Golden("remove-tabs-from-tab-group", RemoveTabsFromGroupRequest(tabs: [SurfaceID(rawValue: 5)]),
               ["surfaces": .array([.number(5)])]),
        Golden("remove-tabs-from-tab-group with every field",
               RemoveTabsFromGroupRequest(tabs: [SurfaceID(rawValue: 5)], transaction: transaction),
               ["surfaces": .array([.number(5)]), "transaction": .string("tx-1")]),
        Golden("move-tab-group", MoveTabGroupRequest(group: group, pane: PaneID(rawValue: 7), index: 0),
               ["group": .string("tgrp_1"), "pane": .number(7), "index": .number(0)]),
        Golden("move-tab-group with every field",
               MoveTabGroupRequest(group: group, pane: PaneID(rawValue: 7), index: 2, transaction: transaction),
               ["group": .string("tgrp_1"), "pane": .number(7), "index": .number(2), "transaction": .string("tx-1")]),
        Golden("move-tab-group-to-split",
               MoveTabGroupToSplitRequest(group: group, pane: PaneID(rawValue: 7), edge: .left),
               ["group": .string("tgrp_1"), "pane": .number(7), "edge": .string("left")]),
        Golden("move-tab-group-to-split with every field",
               MoveTabGroupToSplitRequest(group: group, pane: PaneID(rawValue: 7), edge: .bottom, ratio: 0.25,
                                          transaction: transaction),
               ["group": .string("tgrp_1"), "pane": .number(7), "edge": .string("bottom"), "ratio": .number(0.25),
                "transaction": .string("tx-1")]),
        // The drop target is `screen` or `pane`, never both.
        Golden("move-tab-group-to-column by screen",
               MoveTabGroupToColumnRequest(group: group, target: .screen(ScreenID(rawValue: 2))),
               ["group": .string("tgrp_1"), "screen": .number(2)]),
        Golden("move-tab-group-to-column by pane with every field",
               MoveTabGroupToColumnRequest(group: group, target: .pane(PaneID(rawValue: 7)),
                                           afterColumn: ColumnID(rawValue: 11), width: 0.5, transaction: transaction),
               ["group": .string("tgrp_1"), "pane": .number(7), "after_column": .number(11), "width": .number(0.5),
                "transaction": .string("tx-1")]),
        Golden("move-tab-group-to-new-workspace", MoveTabGroupToNewWorkspaceRequest(group: group),
               ["group": .string("tgrp_1")]),
        Golden("move-tab-group-to-new-workspace with every field",
               MoveTabGroupToNewWorkspaceRequest(group: group, workspaceGroup: WorkspaceGroupID(rawValue: "wg-1"),
                                                 index: 3, transaction: transaction),
               ["group": .string("tgrp_1"), "workspace_group": .string("wg-1"), "index": .number(3),
                "transaction": .string("tx-1")]),
        Golden("list-saved-tab-groups", ListSavedTabGroupsRequest(), [:]),
        Golden("save-tab-group", SaveTabGroupRequest(group: group), ["group": .string("tgrp_1")]),
        Golden("unsave-tab-group", UnsaveTabGroupRequest(group: group), ["group": .string("tgrp_1")]),
        Golden("delete-saved-tab-group", DeleteSavedTabGroupRequest(saved: SavedTabGroupID(rawValue: "stg_1")),
               ["saved": .string("stg_1")]),
        Golden("reopen-saved-tab-group",
               ReopenSavedTabGroupRequest(saved: SavedTabGroupID(rawValue: "stg_1"), pane: PaneID(rawValue: 7)),
               ["saved": .string("stg_1"), "pane": .number(7)]),
        Golden("reopen-saved-tab-group with every field",
               ReopenSavedTabGroupRequest(saved: SavedTabGroupID(rawValue: "stg_1"), pane: PaneID(rawValue: 7),
                                          transaction: transaction),
               ["saved": .string("stg_1"), "pane": .number(7), "transaction": .string("tx-1")]),
    ]

    @Test(arguments: goldens)
    func sendsItsGoldenLine(_ golden: Golden) throws {
        let line = try JSONDecoder().decode(JSONValue.self, from: golden.encode())
        #expect(line == .object(golden.fields))
    }

    /// Every key a golden sends is a request field of its command in cmux-tui/spec/sdk-schema.json, every
    /// required field is sent, and the command is one the macOS app calls, so RequestEmitter generates a
    /// type with exactly these members.
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
            guard case .object(let request)? = command["request"], case .object(let fields)? = request["fields"] else {
                Issue.record("\(golden.command) has no request fields")
                continue
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
    @Test func everyTabGroupsCommandHasAGolden() {
        let covered = Set(Self.goldens.map(\.command))
        let commands: Set = [
            ListTabGroupsRequest.command, CreateTabGroupRequest.command, UpdateTabGroupRequest.command,
            UngroupTabGroupRequest.command, CloseTabGroupRequest.command, AddTabsToGroupRequest.command,
            RemoveTabsFromGroupRequest.command, MoveTabGroupRequest.command, MoveTabGroupToSplitRequest.command,
            MoveTabGroupToColumnRequest.command, MoveTabGroupToNewWorkspaceRequest.command,
            ListSavedTabGroupsRequest.command, SaveTabGroupRequest.command, UnsaveTabGroupRequest.command,
            DeleteSavedTabGroupRequest.command, ReopenSavedTabGroupRequest.command,
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

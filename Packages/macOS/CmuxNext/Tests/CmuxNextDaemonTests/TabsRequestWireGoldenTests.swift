import Foundation
import Testing
@testable import CmuxNextDaemon

/// The wire golden of every request in Sources/CmuxNextDaemon/Requests/Tabs: the
/// line each one sends today, compared as JSON (key order does not count). The migration to the
/// generated `<Name>Request` types (CmuxNextWireGen RequestEmitter) must send the same lines; the
/// generated coder writes each member under its schema wire name, so a golden that holds here and
/// after the migration proves the bytes did not change.
///
/// Fields whose value holds caller-authored keys are not renamed by either coder (the snake-case
/// strategy leaves a `[String: V]` alone; WireKeyInventory.dictionaryFields lists them). In this
/// directory: `create-terminal.env` (a map) and `set-frontend-browser-history.history` (a
/// `JsonValue` document, today the `FrontendBrowserHistory` struct, whose explicit CodingKeys are
/// already the snake-case keys the daemon stores). The daemon reads both forms.
struct TabsRequestWireGoldenTests {
    private static let mutation = MutationIdentity(
        origin: "app", mutationID: "m-1", expectedGeneration: DaemonGeneration(rawValue: "gen-1"), expectedRevision: 9
    )
    private static let mutationFields: [String: JSONValue] = [
        "origin": .string("app"), "mutation_id": .string("m-1"), "expected_generation": .string("gen-1"),
        "expected_revision": .number(9),
    ]

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
        Golden("close-surface", CloseTabRequest(surface: SurfaceID(rawValue: 7)), ["surface": .number(7)]),
        Golden("close-pane", ClosePaneRequest(pane: PaneID(rawValue: 3)), ["pane": .number(3)]),
        Golden("close-pane ending terminals", ClosePaneRequest(pane: PaneID(rawValue: 3), endTerminals: true),
               ["pane": .number(3), "end_terminals": .bool(true)]),
        Golden("close-screen", CloseScreenRequest(screen: ScreenID(rawValue: 2)), ["screen": .number(2)]),
        Golden("close-screen ending terminals", CloseScreenRequest(screen: ScreenID(rawValue: 2), endTerminals: true),
               ["screen": .number(2), "end_terminals": .bool(true)]),
        Golden("close-tabs", CloseTabsRequest(surfaces: [SurfaceID(rawValue: 1), SurfaceID(rawValue: 2)],
                                              endTerminals: false, mutation: nil),
               ["surfaces": .array([.number(1), .number(2)])]),
        Golden("close-tabs with every field",
               CloseTabsRequest(surfaces: [SurfaceID(rawValue: 1)], endTerminals: true,
                                transaction: ClientTransactionID(rawValue: "tx-1"), mutation: mutation, reason: .sessionEnd),
               mutationFields.merging([
                   "surfaces": .array([.number(1)]), "end_terminals": .bool(true), "transaction": .string("tx-1"),
                   "reason": .string("session_end"),
               ]) { $1 }),
        Golden("close-terminal", CloseTerminalRequest(terminalID: TerminalID(rawValue: "t1"), mutation: nil),
               ["terminal_id": .string("t1")]),
        Golden("close-terminal with every field",
               CloseTerminalRequest(terminalID: TerminalID(rawValue: "t1"),
                                    terminalIncarnation: TerminalIncarnation(rawValue: "inc-2"), mutation: mutation),
               mutationFields.merging(["terminal_id": .string("t1"), "terminal_incarnation": .string("inc-2")]) { $1 }),
        Golden("create-terminal detached", CreateDetachedTerminalRequest(mutation: nil),
               ["detached": .bool(true), "keep": .bool(true)]),
        // `env` is a map: its keys go out as given, never snake-cased.
        Golden("create-terminal detached with every field",
               CreateDetachedTerminalRequest(cwd: "/tmp/w", size: CellSize(cols: 80, rows: 24),
                                             terminalID: TerminalID(rawValue: "t9"),
                                             env: ["FOO_BAR": "1", "camelKey": "2"], mutation: mutation),
               mutationFields.merging([
                   "detached": .bool(true), "keep": .bool(true), "cwd": .string("/tmp/w"), "cols": .number(80),
                   "rows": .number(24), "terminal_id": .string("t9"),
                   "env": .object(["FOO_BAR": .string("1"), "camelKey": .string("2")]),
               ]) { $1 }),
        Golden("new-frontend-browser-tab", NewFrontendBrowserTabRequest(url: "https://a.test/", engine: .webkit),
               ["url": .string("https://a.test/"), "engine": .string("webkit")]),
        Golden("new-frontend-browser-tab with every field", {
            var request = NewFrontendBrowserTabRequest(
                url: "https://a.test/", engine: .cef, pane: PaneID(rawValue: 4), title: "A", faviconURL: "https://a.test/f.ico",
                profileID: "default", size: CellSize(cols: 100, rows: 30), activate: false, after: SurfaceID(rawValue: 8)
            )
            request.idempotencyKey = "k-1"
            return request
        }(), [
            "url": .string("https://a.test/"), "engine": .string("cef"), "pane": .number(4), "title": .string("A"),
            "favicon_url": .string("https://a.test/f.ico"), "profile_id": .string("default"), "cols": .number(100),
            "rows": .number(30), "activate": .bool(false), "after": .number(8), "idempotency_key": .string("k-1"),
        ]),
        Golden("update-frontend-browser-tab", UpdateFrontendBrowserTabRequest(surface: SurfaceID(rawValue: 5)),
               ["surface": .number(5)]),
        Golden("update-frontend-browser-tab with every field",
               UpdateFrontendBrowserTabRequest(surface: SurfaceID(rawValue: 5), url: "https://b.test/", title: "B",
                                               faviconURL: .set("https://b.test/f.ico")),
               ["surface": .number(5), "url": .string("https://b.test/"), "title": .string("B"),
                "favicon_url": .string("https://b.test/f.ico")]),
        Golden("update-frontend-browser-tab clearing the favicon",
               UpdateFrontendBrowserTabRequest(surface: SurfaceID(rawValue: 5), faviconURL: .clear),
               ["surface": .number(5), "favicon_url": .null]),
        Golden("update-frontend-browser-tab moving the profile",
               SetFrontendBrowserTabProfileRequest(surface: SurfaceID(rawValue: 5), profileID: "default"),
               ["surface": .number(5), "profile_id": .string("default")]),
        Golden("set-frontend-browser-history clearing", SetFrontendBrowserHistoryRequest(surface: SurfaceID(rawValue: 6), history: nil),
               ["surface": .number(6), "history": .null]),
        // `history` is a JsonValue document: the struct's keys are already the stored snake-case keys.
        Golden("set-frontend-browser-history",
               SetFrontendBrowserHistoryRequest(surface: SurfaceID(rawValue: 6), history: FrontendBrowserHistory(
                   entries: [.init(url: "https://a.test/", title: "A", scrollY: 12, formPost: true)], index: 0,
                   engineState: .init(engine: "webkit-2", data: "AAAA")
               )),
               ["surface": .number(6), "history": .object([
                   "entries": .array([.object([
                       "url": .string("https://a.test/"), "title": .string("A"), "scroll_y": .number(12), "form_post": .bool(true),
                   ])]),
                   "index": .number(0),
                   "engine_state": .object(["engine": .string("webkit-2"), "data": .string("AAAA")]),
               ])]),
        Golden("get-frontend-browser-history", GetFrontendBrowserHistoryRequest(surface: SurfaceID(rawValue: 6)),
               ["surface": .number(6)]),
        Golden("process-info", TerminalProcessInfoRequest(surface: SurfaceID(rawValue: 7)), ["surface": .number(7)]),
        Golden("new-remote-terminal-tab",
               NewRemoteTerminalTabRequest(RemoteTerminalRef(sessionID: "S-1", terminalID: TerminalID(rawValue: "t2"),
                                                             sessionName: "box")),
               ["session_id": .string("s-1"), "terminal_id": .string("t2"), "session_name": .string("box")]),
        Golden("new-remote-terminal-tab with every field",
               NewRemoteTerminalTabRequest(RemoteTerminalRef(sessionID: "s-1", terminalID: TerminalID(rawValue: "t2"),
                                                             sessionName: "box"),
                                           pane: PaneID(rawValue: 4), title: "T", size: CellSize(cols: 90, rows: 20)),
               ["session_id": .string("s-1"), "terminal_id": .string("t2"), "session_name": .string("box"),
                "pane": .number(4), "title": .string("T"), "cols": .number(90), "rows": .number(20)]),
        Golden("update-remote-terminal-tab", UpdateRemoteTerminalTabRequest(surface: SurfaceID(rawValue: 9)),
               ["surface": .number(9)]),
        Golden("update-remote-terminal-tab with every field",
               UpdateRemoteTerminalTabRequest(surface: SurfaceID(rawValue: 9), title: .set("T"), sessionName: "box",
                                              snapshot: .clear),
               ["surface": .number(9), "title": .string("T"), "session_name": .string("box"), "snapshot": .null]),
        Golden("remote-terminal-snapshot", RemoteTerminalSnapshotRequest(surface: SurfaceID(rawValue: 9)),
               ["surface": .number(9)]),
        Golden("rename-surface", RenameTabRequest(surface: SurfaceID(rawValue: 7), name: "N"),
               ["surface": .number(7), "name": .string("N")]),
        Golden("rename-pane", RenamePaneRequest(pane: PaneID(rawValue: 3), name: ""),
               ["pane": .number(3), "name": .string("")]),
        Golden("rename-screen", RenameScreenRequest(screen: ScreenID(rawValue: 2), name: "S"),
               ["screen": .number(2), "name": .string("S")]),
        Golden("park-tabs", ParkTabsRequest(surfaces: [SurfaceID(rawValue: 1), SurfaceID(rawValue: 2)]),
               ["surfaces": .array([.number(1), .number(2)])]),
        Golden("set-tab-pinned", SetTabPinnedRequest(surface: SurfaceID(rawValue: 7), pinned: true),
               ["surface": .number(7), "pinned": .bool(true)]),
        Golden("restart-tab", RestartTabRequest(surface: SurfaceID(rawValue: 7)), ["surface": .number(7)]),
        Golden("set-terminal-keep by surface", SetTerminalKeepRequest(.surface(SurfaceID(rawValue: 7)), keep: true),
               ["surface": .number(7), "keep": .bool(true)]),
        Golden("set-terminal-keep by terminal", SetTerminalKeepRequest(.terminal(TerminalID(rawValue: "t3")), keep: false),
               ["terminal_id": .string("t3"), "keep": .bool(false)]),
        Golden("terminal-resources for every surface", TerminalResourcesRequest(surfaces: nil), [:]),
        Golden("terminal-resources", TerminalResourcesRequest(surfaces: [SurfaceID(rawValue: 1)]),
               ["surfaces": .array([.number(1)])]),
        Golden("terminal-resume-command read", TerminalResumeCommandRequest(.surface(SurfaceID(rawValue: 7))),
               ["surface": .number(7)]),
        Golden("terminal-resume-command set", TerminalResumeCommandRequest(.terminal(TerminalID(rawValue: "t3")),
                                                                           change: .set("make test")),
               ["terminal_id": .string("t3"), "command": .string("make test")]),
        // An explicit null clears; an absent `command` only reads.
        Golden("terminal-resume-command clear", TerminalResumeCommandRequest(.surface(SurfaceID(rawValue: 7)), change: .clear),
               ["surface": .number(7), "command": .null]),
    ]

    @Test(arguments: goldens)
    func sendsItsGoldenLine(_ golden: Golden) throws {
        let line = try JSONDecoder().decode(JSONValue.self, from: golden.encode())
        #expect(line == .object(golden.fields))
    }

    /// Every key a golden sends is a request field of its command in cmux-tui/spec/sdk-schema.json, and the
    /// command is one the macOS app calls, so RequestEmitter generates a type with each of these members.
    @Test func sendsOnlySchemaFields() throws {
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
            let extra = Set(golden.fields.keys).subtracting(["id", "cmd"]).subtracting(fields.keys)
            #expect(extra.isEmpty, "\(golden.name): not schema fields of \(golden.command): \(extra.sorted())")
        }
    }

    /// Every request type of the directory has a golden.
    @Test func everyTabsCommandHasAGolden() {
        let covered = Set(Self.goldens.map(\.command))
        let commands: Set = [
            CloseTabRequest.command, ClosePaneRequest.command, CloseScreenRequest.command, CloseTabsRequest.command,
            CloseTerminalRequest.command, CreateDetachedTerminalRequest.command, NewFrontendBrowserTabRequest.command,
            UpdateFrontendBrowserTabRequest.command, SetFrontendBrowserTabProfileRequest.command,
            SetFrontendBrowserHistoryRequest.command, GetFrontendBrowserHistoryRequest.command,
            TerminalProcessInfoRequest.command, NewRemoteTerminalTabRequest.command, UpdateRemoteTerminalTabRequest.command,
            RemoteTerminalSnapshotRequest.command, RenameTabRequest.command, RenamePaneRequest.command,
            RenameScreenRequest.command, ParkTabsRequest.command, SetTabPinnedRequest.command, RestartTabRequest.command,
            SetTerminalKeepRequest.command, TerminalResourcesRequest.command, TerminalResumeCommandRequest.command,
        ]
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

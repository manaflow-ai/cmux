import Foundation
import Testing
@testable import CmuxNextDaemon

/// The wire golden of every request in Sources/CmuxNextDaemon/Requests/Bookmarks, History,
/// Projection, Terminals, Machines and Requests/PairingResponseRequest.swift: the line
/// each one sends today, compared as JSON (key order does not count). The migration to the generated
/// `<Name>Request` types (CmuxNextWireGen RequestEmitter) must send the same lines.
///
/// Requests/Resource holds no raw protocol command: its `cmux.protocol/2` envelope is pinned by
/// ResourceRequestLineParityTests, and the generated envelope builder by
/// ResourceRequestLineTests.
///
/// No dictionary-valued field here. `projection` is a `JsonValue` ref, sent as given; a null
/// projection is sent as an explicit null (it is a required field).
///
/// One listed byte change: the bookmark mutations encode the whole MutationIdentity, so CAS guards
/// on it would send `expected_generation` and `expected_revision`, which the bookmark commands do
/// not have in the schema. The daemon's bookmark params do not deny unknown fields and drop them; the
/// app sets none (BookmarkService+Daemon passes origin and mutation id only), and the generated types
/// have no member for them (`outsideSchema` names them).
struct BookmarksHistoryProjectionRequestWireGoldenTests {
    private static let key = MutationIdentity(origin: "app", mutationID: "m-1")
    private static let keyFields: [String: JSONValue] = ["origin": .string("app"), "mutation_id": .string("m-1")]
    private static let guarded = MutationIdentity(
        origin: "app", mutationID: "m-1", expectedGeneration: DaemonGeneration(rawValue: "gen-1"), expectedRevision: 9
    )
    private static let guardedFields: [String: JSONValue] = [
        "origin": .string("app"), "mutation_id": .string("m-1"), "expected_generation": .string("gen-1"),
        "expected_revision": .number(9),
    ]
    private static let owner: ResourceID = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private static let remote: ResourceID = "machine_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    /// One request's expected line, `id` and `cmd` included. `outsideSchema` names the sent keys
    /// that are not request fields of the command in the schema (the listed byte change).
    struct Golden: Sendable, CustomTestStringConvertible {
        let name: String
        let encode: @Sendable () throws -> Data
        let command: String
        let requiredCapability: String?
        let fields: [String: JSONValue]
        let outsideSchema: Set<String>

        init<R: DaemonRequest>(_ name: String, _ request: R, _ fields: [String: JSONValue],
                               outsideSchema: Set<String> = []) {
            self.name = name
            encode = { try WireCoding.encodeRequest(request, id: 1) }
            command = R.command
            requiredCapability = R.requiredCapability
            var line = fields
            line["id"] = .number(1)
            line["cmd"] = .string(R.command)
            self.fields = line
            self.outsideSchema = outsideSchema
        }

        var testDescription: String { name }
    }

    private static func merged(_ parts: [String: JSONValue]...) -> [String: JSONValue] {
        parts.reduce(into: [:]) { line, part in line.merge(part) { _, new in new } }
    }

    static let bookmarkGoldens: [Golden] = [
        Golden("list-bookmarks", ListBookmarksRequest(browserProfileID: "default"),
               ["browser_profile_id": .string("default")]),
        Golden("create-bookmark",
               CreateBookmarkRequest(bookmark: nil, browserProfileID: "default", parent: "bar", index: nil, kind: "url",
                                     title: "T", url: nil, faviconKey: nil, sourceKey: nil, createdMs: nil, mutation: nil),
               ["browser_profile_id": .string("default"), "parent": .string("bar"), "kind": .string("url"),
                "title": .string("T")]),
        // A caller-chosen `bookmark` id makes a retry return the stored node.
        Golden("create-bookmark with every field",
               CreateBookmarkRequest(bookmark: "bm-1", browserProfileID: "default", parent: "bar", index: 2, kind: "url",
                                     title: "T", url: "https://a.example/x", faviconKey: "fav-1", sourceKey: "src-1",
                                     createdMs: 1_700_000_000_000, mutation: key),
               merged(["bookmark": .string("bm-1"), "browser_profile_id": .string("default"), "parent": .string("bar"),
                       "index": .number(2), "kind": .string("url"), "title": .string("T"),
                       "url": .string("https://a.example/x"), "favicon_key": .string("fav-1"),
                       "source_key": .string("src-1"), "created_ms": .number(1_700_000_000_000)], keyFields)),
        Golden("update-bookmark", UpdateBookmarkRequest(bookmark: "bm-1", mutation: nil), ["bookmark": .string("bm-1")]),
        Golden("update-bookmark with every field",
               UpdateBookmarkRequest(bookmark: "bm-1", title: "T", url: "https://a.example/", faviconKey: .set("fav-1"),
                                     lastUsedMs: .set(42), icon: .set("star"), mutation: key),
               merged(["bookmark": .string("bm-1"), "title": .string("T"), "url": .string("https://a.example/"),
                       "favicon_key": .string("fav-1"), "last_used_ms": .number(42), "icon": .string("star")], keyFields)),
        // `.clear` sends an explicit null; an absent field is unchanged.
        Golden("update-bookmark clearing favicon_key, last_used_ms and icon",
               UpdateBookmarkRequest(bookmark: "bm-1", faviconKey: .clear, lastUsedMs: .clear, icon: .clear, mutation: nil),
               ["bookmark": .string("bm-1"), "favicon_key": .null, "last_used_ms": .null, "icon": .null]),
        Golden("update-bookmark with CAS guards", UpdateBookmarkRequest(bookmark: "bm-1", mutation: guarded),
               merged(["bookmark": .string("bm-1")], guardedFields),
               outsideSchema: ["expected_generation", "expected_revision"]),
        Golden("move-bookmark", MoveBookmarkRequest(bookmark: "bm-1", parent: "other", index: 0, mutation: nil),
               ["bookmark": .string("bm-1"), "parent": .string("other"), "index": .number(0)]),
        Golden("move-bookmark with every field", MoveBookmarkRequest(bookmark: "bm-1", parent: "other", index: 3, mutation: key),
               merged(["bookmark": .string("bm-1"), "parent": .string("other"), "index": .number(3)], keyFields)),
        Golden("delete-bookmark", DeleteBookmarkRequest(bookmark: "bm-1", mutation: nil), ["bookmark": .string("bm-1")]),
        Golden("delete-bookmark with every field", DeleteBookmarkRequest(bookmark: "bm-1", mutation: key),
               merged(["bookmark": .string("bm-1")], keyFields)),
        Golden("import-bookmarks",
               ImportBookmarksRequest(browserProfileID: "default", parent: "bar", index: nil, sourceKey: nil, replace: nil,
                                      nodes: [], mutation: nil),
               ["browser_profile_id": .string("default"), "parent": .string("bar"), "nodes": .array([])]),
        // Nested nodes keep `created_ms` and leave out absent members at every depth.
        Golden("import-bookmarks with every field",
               ImportBookmarksRequest(
                   browserProfileID: "default", parent: "bar", index: 1, sourceKey: "chrome:Default", replace: true,
                   nodes: [
                       BookmarkImportNode(kind: "folder", title: "F", url: nil, createdMs: 5, children: [
                           BookmarkImportNode(kind: "url", title: "A", url: "https://a.example/", createdMs: 6, children: nil),
                           BookmarkImportNode(kind: "url", title: "B", url: "https://b.example/", createdMs: nil, children: nil),
                       ]),
                   ],
                   mutation: key),
               merged(["browser_profile_id": .string("default"), "parent": .string("bar"), "index": .number(1),
                       "source_key": .string("chrome:Default"), "replace": .bool(true),
                       "nodes": .array([.object([
                           "kind": .string("folder"), "title": .string("F"), "created_ms": .number(5),
                           "children": .array([
                               .object(["kind": .string("url"), "title": .string("A"), "url": .string("https://a.example/"),
                                        "created_ms": .number(6)]),
                               .object(["kind": .string("url"), "title": .string("B"), "url": .string("https://b.example/")]),
                           ]),
                       ])])], keyFields)),
    ]

    static let historyGoldens: [Golden] = [
        Golden("set-terminal-command-history", SetTerminalCommandHistoryRequest(enabled: false), ["enabled": .bool(false)]),
        Golden("set-terminal-command-history with every field",
               SetTerminalCommandHistoryRequest(enabled: true, retentionDays: 30),
               ["enabled": .bool(true), "retention_days": .number(30)]),
        Golden("list-terminal-commands", ListTerminalCommandsRequest(), [:]),
        Golden("list-terminal-commands with every field", ListTerminalCommandsRequest(afterID: "17", limit: 500),
               ["after_id": .string("17"), "limit": .number(500)]),
        Golden("delete-terminal-commands by ids", DeleteTerminalCommandsRequest(.ids(["1", "2"])),
               ["ids": .array([.string("1"), .string("2")])]),
        // Milliseconds as a decimal string.
        Golden("delete-terminal-commands started since",
               DeleteTerminalCommandsRequest(.startedSince(Date(timeIntervalSince1970: 1_700_000_000.25))),
               ["started_since_ms": .string("1700000000250")]),
        // A date before 1970 clamps to 0 instead of trapping.
        Golden("delete-terminal-commands started since before 1970",
               DeleteTerminalCommandsRequest(.startedSince(Date(timeIntervalSince1970: -5))),
               ["started_since_ms": .string("0")]),
        Golden("delete-terminal-commands all", DeleteTerminalCommandsRequest(.all), ["all": .bool(true)]),
    ]

    static let projectionGoldens: [Golden] = [
        Golden("get-frontend-projection",
               GetFrontendProjectionRequest(frontend: "cmux-next", scope: .personal, subjectKey: "window-1"),
               ["frontend": .string("cmux-next"), "scope": .string("personal"), "subject_key": .string("window-1")]),
        // The projection document goes as given: its own keys are not renamed.
        Golden("put-frontend-projection",
               PutFrontendProjectionRequest(frontend: "cmux-next", scope: .shared, subjectKey: "window-1", schemaVersion: 2,
                                            projection: .object(["sidebarWidth": .number(240)]), mutation: key),
               merged(["frontend": .string("cmux-next"), "scope": .string("shared"), "subject_key": .string("window-1"),
                       "schema_version": .number(2), "projection": .object(["sidebarWidth": .number(240)])], keyFields)),
        Golden("put-frontend-projection with every field",
               PutFrontendProjectionRequest(frontend: "cmux-next", scope: .personal, subjectKey: "window-1", schemaVersion: 2,
                                            projection: .object(["a": .array([.bool(true), .null])]),
                                            expectedProjectionRevision: 7, mutation: guarded),
               merged(["frontend": .string("cmux-next"), "scope": .string("personal"), "subject_key": .string("window-1"),
                       "schema_version": .number(2), "projection": .object(["a": .array([.bool(true), .null])]),
                       "expected_projection_revision": .number(7)], guardedFields)),
        // A required field: a null projection is sent as null, never left out.
        Golden("put-frontend-projection with a null projection",
               PutFrontendProjectionRequest(frontend: "cmux-next", scope: .personal, subjectKey: "window-1", schemaVersion: 1,
                                            projection: .null, mutation: key),
               merged(["frontend": .string("cmux-next"), "scope": .string("personal"), "subject_key": .string("window-1"),
                       "schema_version": .number(1), "projection": .null], keyFields)),
    ]

    static let otherGoldens: [Golden] = [
        Golden("list-terminals", ListTerminalsRequest(), [:]),
        Golden("machine-catalog-publish withdrawing every route",
               MachineCatalogPublishRequest(expectedMachineID: owner, sequence: 1, machines: []),
               ["expected_machine_id": .string(owner.rawValue), "sequence": .number(1), "machines": .array([])]),
        // A record without an observed platform leaves `platform` out; capabilities always go.
        Golden("machine-catalog-publish with every field",
               MachineCatalogPublishRequest(expectedMachineID: owner, sequence: 7, machines: [
                   MachineCatalogRecord(id: remote, name: "server", origin: .ssh, status: .running,
                                        platform: MachineCatalogPlatform(os: "linux", arch: "aarch64"),
                                        capabilities: ["terminal"]),
                   MachineCatalogRecord(id: "machine_cccccccccccccccccccccccccccccccc", name: "vm", origin: .cloud,
                                        status: .unavailable, platform: MachineCatalogPlatform(os: "macos")),
               ].compactMap { $0 }),
               ["expected_machine_id": .string(owner.rawValue), "sequence": .number(7), "machines": .array([
                   .object(["id": .string(remote.rawValue), "name": .string("server"), "origin": .string("ssh"),
                            "status": .string("running"),
                            "platform": .object(["os": .string("linux"), "arch": .string("aarch64")]),
                            "capabilities": .array([.string("terminal")])]),
                   .object(["id": .string("machine_cccccccccccccccccccccccccccccccc"), "name": .string("vm"),
                            "origin": .string("cloud"), "status": .string("unavailable"),
                            "platform": .object(["os": .string("macos")]), "capabilities": .array([])]),
               ])]),
        Golden("pairing-response approve", PairingResponseRequest(request: 12, approve: true),
               ["request": .number(12), "approve": .bool(true)]),
        Golden("pairing-response deny", PairingResponseRequest(request: 12, approve: false),
               ["request": .number(12), "approve": .bool(false)]),
    ]

    static let goldens = bookmarkGoldens + historyGoldens + projectionGoldens + otherGoldens

    /// Commands whose hand-written type does not declare the capability the schema gives the
    /// command: the hand-written type sends them to any daemon. The generated type takes its
    /// capability from the MethodTable, so after the migration the app refuses these on a daemon
    /// that does not advertise it (a listed behavior change, not a byte change).
    static let capabilityNotDeclaredToday: Set<String> = ["list-terminal-commands", "delete-terminal-commands"]

    @Test(arguments: goldens)
    func sendsItsGoldenLine(_ golden: Golden) throws {
        let line = try JSONDecoder().decode(JSONValue.self, from: golden.encode())
        #expect(line == .object(golden.fields))
    }

    /// Every key a golden sends is a request field of its command in cmux-tui/spec/sdk-schema.json
    /// or listed in `outsideSchema`, every required field is sent, a null goes only to a nullable
    /// field, and the command is one the macOS app calls, so RequestEmitter generates a type with
    /// these members.
    @Test func sendsSchemaFields() throws {
        let commands = try Self.schemaCommands()
        for golden in Self.goldens {
            let fields = try Self.requestFields(golden.command, in: commands)
            let sent = Set(golden.fields.keys).subtracting(["id", "cmd"])
            let extra = sent.subtracting(fields.keys).subtracting(golden.outsideSchema)
            #expect(extra.isEmpty, "\(golden.name): not schema fields of \(golden.command): \(extra.sorted())")
            #expect(golden.outsideSchema.isSubset(of: sent), "\(golden.name): outsideSchema keys not sent")
            #expect(golden.outsideSchema.isDisjoint(with: fields.keys), "\(golden.name): outsideSchema keys are fields")
            var required: Set<String> = []
            var nullable: Set<String> = []
            for (name, value) in fields {
                guard case .object(let spec) = value else { continue }
                if spec["presence"] == JSONValue.string("required") { required.insert(name) }
                if spec["nullable"] == JSONValue.bool(true) { nullable.insert(name) }
            }
            let missing = required.subtracting(sent)
            #expect(missing.isEmpty, "\(golden.name): required fields of \(golden.command) not sent: \(missing.sorted())")
            let nulls = Set(golden.fields.compactMap { entry in entry.value == JSONValue.null ? entry.key : nil })
            let notNullable = nulls.subtracting(nullable)
            #expect(notNullable.isEmpty, "\(golden.name): null sent to non-nullable fields: \(notNullable.sorted())")
        }
    }

    /// Each hand-written type's ``DaemonRequest/requiredCapability`` equals the schema's
    /// `capability` of its command, except the commands listed in `capabilityNotDeclaredToday`.
    @Test func declaresTheSchemaCapability() throws {
        let commands = try Self.schemaCommands()
        var differing: Set<String> = []
        for golden in Self.goldens {
            guard case .object(let spec)? = commands[golden.command] else { throw SchemaShapeError.missing(golden.command) }
            var schemaCapability: String?
            if case .string(let name)? = spec["capability"] { schemaCapability = name }
            if golden.requiredCapability != schemaCapability {
                #expect(golden.requiredCapability == nil, "\(golden.command) declares \(golden.requiredCapability ?? "")")
                differing.insert(golden.command)
            }
        }
        #expect(differing == Self.capabilityNotDeclaredToday)
    }

    /// Every request type of the directories has a golden.
    @Test func everyCommandOfTheDirectoriesHasAGolden() {
        let covered = Set(Self.goldens.map(\.command))
        let commands: Set = [
            ListBookmarksRequest.command, CreateBookmarkRequest.command, UpdateBookmarkRequest.command,
            MoveBookmarkRequest.command, DeleteBookmarkRequest.command, ImportBookmarksRequest.command,
            SetTerminalCommandHistoryRequest.command, ListTerminalCommandsRequest.command,
            DeleteTerminalCommandsRequest.command, GetFrontendProjectionRequest.command,
            PutFrontendProjectionRequest.command, ListTerminalsRequest.command, MachineCatalogPublishRequest.command,
            PairingResponseRequest.command,
        ]
        #expect(commands.count == 14)
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

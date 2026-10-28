import Foundation
import Testing
@testable import CmuxNextDaemon

/// A personal projection document this build cannot read (a newer build saved another schema, or a field
/// shape that does not decode here) is never overwritten. Before, the store showed an empty document but
/// kept the stored revision, so the next save of one window passed the compare-and-swap and erased every
/// other saved window, the collapsed groups and the legacy agent tabs: going back from the nightly to the
/// release build and moving one window lost all saved window state.
///
/// The daemon is a bounded test bridge that keeps the projections in memory with the daemon's
/// compare-and-swap; it never launches a user daemon or app.
struct ProjectionDowngradeTests {
    private static let script = #"""
    import json, sys
    store = json.loads(sys.argv[1])
    for entry in store.values():
        entry['schema_version'] = int(entry['schema_version'])
        entry['revision'] = int(entry['revision'])
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        data = {}
        error = None
        if command == 'identify':
            data = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'projection-downgrade-test', 'capabilities': []}
        elif command in ('get-frontend-projection', 'put-frontend-projection'):
            key = frame['subject_key']
            entry = store.get(key, {'schema_version': 0, 'revision': 0, 'projection': None})
            if command == 'put-frontend-projection':
                expected = frame.get('expected_projection_revision')
                if expected is not None and expected != entry['revision']:
                    error = 'projection revision conflict: expected %d, current %d' % (expected, entry['revision'])
                else:
                    entry = {'schema_version': frame['schema_version'], 'revision': entry['revision'] + 1,
                             'projection': frame['projection']}
                    store[key] = entry
            data = {'frontend': frame['frontend'], 'scope': frame['scope'], 'subject_key': key,
                    'schema_version': entry['schema_version'], 'projection_revision': entry['revision'],
                    'projection': entry['projection']}
        reply = {'id': frame.get('id'), 'ok': error is None, 'data': data}
        if error is not None:
            reply.update(error=error, error_code='conflict')
        print(json.dumps(reply), flush=True)
    """#

    /// A window-state document a newer build wrote: several windows, collapsed groups, legacy agent tabs.
    private static let newerWindows = #"""
    {"windows":[{"id":"w1","workspace_keys":[],"is_full_screen":false,"sidebar_hidden":false,"selected_tabs":{},"focused_panes":{},"order":0,"profile_workspaces":{},"is_closed":false},{"id":"w2","workspace_keys":[],"is_full_screen":false,"sidebar_hidden":false,"selected_tabs":{},"focused_panes":{},"order":1,"profile_workspaces":{},"is_closed":false}],"collapsed_groups":{"g1":true},"agent_tabs":{"p1":[{"id":"t1","session":"s1"}]},"tab_groups_v2":{"w1":["a","b"]}}
    """#

    private struct Stored {
        var schemaVersion: UInt32
        var revision: UInt64
        var projection: String
    }

    private static func seed(_ documents: [String: Stored]) throws -> String {
        var store: [String: JSONValue] = [:]
        for (subject, stored) in documents {
            store[subject] = .object([
                "schema_version": .number(Double(stored.schemaVersion)),
                "revision": .number(Double(stored.revision)),
                "projection": try JSONDecoder().decode(JSONValue.self, from: Data(stored.projection.utf8)),
            ])
        }
        return String(decoding: try JSONEncoder().encode(JSONValue.object(store)), as: UTF8.self)
    }

    private static func withDaemon(_ documents: [String: Stored],
                                   _ body: (DaemonConnection) async throws -> Void) async throws {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, try seed(documents)])
        let endpoint = DaemonEndpoint(socketPath: "/tmp/cmux-projection-downgrade-\(UUID().uuidString).sock", bridge: bridge)
        let connection = DaemonConnection(endpoint: endpoint, configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        do {
            try await connection.start()
            try await body(connection)
        } catch {
            await connection.close()
            throw error
        }
        await connection.close()
    }

    /// The stored projection is exactly the one seeded: same schema, revision and JSON.
    private static func expectUntouched(_ connection: DaemonConnection, subject: String, _ seeded: Stored,
                                        sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let stored = try await connection.frontendProjection(subject: subject)
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(seeded.projection.utf8))
        #expect(stored.schemaVersion == seeded.schemaVersion, "the schema was overwritten", sourceLocation: sourceLocation)
        #expect(stored.projectionRevision == seeded.revision, "the document was written", sourceLocation: sourceLocation)
        #expect(stored.projection == expected, "the stored document changed: \(stored.projection)", sourceLocation: sourceLocation)
    }

    @Test func aWindowDocumentOfANewerSchemaIsNeverOverwritten() async throws {
        let seeded = Stored(schemaVersion: WindowStateDocument.schemaVersion + 1, revision: 7, projection: Self.newerWindows)
        try await Self.withDaemon(["windows": seeded]) { connection in
            let store = WindowStateStore(connection: connection)
            #expect(try await store.load().windows.isEmpty, "a newer schema shows as no saved windows")
            await #expect(throws: (any Error).self, "a save over a newer schema must refuse") {
                try await store.save(window: WindowRecord(id: "w3"))
            }
            try await Self.expectUntouched(connection, subject: "windows", seeded)
        }
    }

    @Test func anUndecodableWindowDocumentIsNeverOverwritten() async throws {
        let seeded = Stored(schemaVersion: WindowStateDocument.schemaVersion, revision: 4,
                            projection: #"{"windows":"a shape a newer build writes","collapsed_groups":{"g1":true}}"#)
        try await Self.withDaemon(["windows": seeded]) { connection in
            let store = WindowStateStore(connection: connection)
            #expect(try await store.load().windows.isEmpty)
            await #expect(throws: (any Error).self, "a save over a document that does not decode must refuse") {
                try await store.save(window: WindowRecord(id: "w3"))
            }
            try await Self.expectUntouched(connection, subject: "windows", seeded)
        }
    }

    /// The store's first save conflicts (another build saved first) and its reload reads a newer schema:
    /// the retry refuses instead of writing over it.
    @Test func aConflictThatReloadsANewerSchemaRefusesTheRetry() async throws {
        let readable = #"{"windows":[],"collapsed_groups":{}}"#
        try await Self.withDaemon(["windows": Stored(schemaVersion: WindowStateDocument.schemaVersion, revision: 1, projection: readable)]) { connection in
            let store = WindowStateStore(connection: connection)
            _ = try await store.load()
            let newer = try JSONDecoder().decode(JSONValue.self, from: Data(Self.newerWindows.utf8))
            try await connection.putFrontendProjection(subject: "windows", schemaVersion: WindowStateDocument.schemaVersion + 1,
                                                       projection: newer, expectedRevision: 1)
            await #expect(throws: (any Error).self, "the retry after the conflict must refuse") {
                try await store.save(window: WindowRecord(id: "w3"))
            }
            try await Self.expectUntouched(connection, subject: "windows",
                                           Stored(schemaVersion: WindowStateDocument.schemaVersion + 1, revision: 2, projection: Self.newerWindows))
        }
    }

    /// Once a later load reads a document the store understands, it saves again (and keeps the CAS merge).
    @Test func aLaterReadableLoadSavesAgain() async throws {
        let seeded = Stored(schemaVersion: WindowStateDocument.schemaVersion + 1, revision: 3, projection: Self.newerWindows)
        try await Self.withDaemon(["windows": seeded]) { connection in
            let store = WindowStateStore(connection: connection)
            _ = try await store.load()
            let readable = try WindowStateDocument(windows: [WindowRecord(id: "w1")]).jsonValue()
            try await connection.putFrontendProjection(subject: "windows", schemaVersion: WindowStateDocument.schemaVersion,
                                                       projection: readable, expectedRevision: 3)
            #expect(try await store.load().windows.map(\.id) == ["w1"])
            try await store.save(window: WindowRecord(id: "w2"))
            let reloaded = WindowStateStore(connection: connection)
            #expect(try await reloaded.load().windows.map(\.id) == ["w1", "w2"])
        }
    }

    @Test func savedHostsOfANewerSchemaAreNeverOverwritten() async throws {
        let seeded = Stored(schemaVersion: SavedHostsDocument.schemaVersion + 1, revision: 5,
                            projection: #"{"hosts":[{"id":"h1","transport":{"route":"ssh"},"added_ms":1}],"groups":["g"]}"#)
        try await Self.withDaemon([SavedHostsStore.subject: seeded]) { connection in
            let store = SavedHostsStore(connection: connection)
            #expect(try await store.load().hosts.isEmpty, "a newer schema shows as no saved hosts")
            await #expect(throws: (any Error).self, "a save over a newer schema must refuse") {
                try await store.update { $0.upsert(id: "h2", transport: ["route": "ssh"], nowMs: 2) }
            }
            try await Self.expectUntouched(connection, subject: SavedHostsStore.subject, seeded)
        }
    }
}

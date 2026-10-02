import Foundation
import Testing
@testable import CmuxNextDaemon

/// `launch-snapshot-v1`: the app draws the daemon's last settled tree and
/// window records before it connects, then the live tree replaces it in
/// place.
@MainActor @Suite struct LaunchSnapshotTests {
    /// The `list-workspaces` reply of the fixture, as the daemon stores it.
    static func treeJSON() throws -> JSONValue {
        let reply = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("list-workspaces.json"))
        return try #require(reply["data"])
    }

    static func file(session: String = "cmux-app-nx", schema: Int = 1, windows: WindowStateDocument?,
                     personal: JSONValue? = nil) throws -> Data {
        var projections: [JSONValue] = []
        if let windows {
            projections.append(.object([
                "frontend": .string(DaemonConnection.origin), "scope": .string("personal"),
                "subject_key": .string(WindowStateStore.defaultSubject),
                "schema_version": .number(Double(WindowStateDocument.schemaVersion)), "projection_revision": .number(3),
                "projection": try windows.jsonValue(),
            ]))
            projections.append(.object([
                "frontend": .string("another-frontend"), "scope": .string("personal"), "subject_key": .string("windows"),
                "schema_version": .number(1), "projection_revision": .number(1), "projection": .object(["windows": .array([])]),
            ]))
        }
        var file: JSONValue = .object([
            "schema_version": .number(Double(schema)), "app": .string("cmux-tui"), "version": .string("0.1"),
            "session": .string(session), "registry_id": .string("b3060a24-9687-41ff-8d16-f0c6cb7b4dee"),
            "generation": .string("cd030a83-d78e-4e46-a7e2-44ead79f7928"), "written_at_ms": .number(1_790_000_000_000),
            "tree": try treeJSON(), "frontend_projections": .array(projections),
        ])
        if let personal, case .object(var fields) = file {
            fields["personal"] = personal
            file = .object(fields)
        }
        return try JSONEncoder().encode(file)
    }

    static let key = WorkspaceKey(rawValue: "c7a12f08-d868-42cd-9f98-a2ca1f6d9eb1")

    @Test func decodesTheTreeAndThisAppsWindowRecords() throws {
        let windows = WindowStateDocument(windows: [WindowRecord(id: "w1", workspaceKey: Self.key, workspaceKeys: [Self.key])])
        let snapshot = try #require(LaunchSnapshot.decode(try Self.file(windows: windows), session: "cmux-app-nx"))
        let live = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        #expect(snapshot.tree == live)
        #expect(snapshot.windows?.windows.map(\.id) == ["w1"])
        #expect(snapshot.windows?.windows.first?.workspaceKey == Self.key)
        #expect(snapshot.writtenAtMs == 1_790_000_000_000)

        // Without saved windows the tree still draws.
        #expect(LaunchSnapshot.decode(try Self.file(windows: nil), session: "cmux-app-nx")?.windows == nil)
        // Another session's file or schema is never shown.
        #expect(LaunchSnapshot.decode(try Self.file(session: "cmux-app-other", windows: windows), session: "cmux-app-nx") == nil)
        #expect(LaunchSnapshot.decode(try Self.file(schema: 2, windows: windows), session: "cmux-app-nx") == nil)
        #expect(LaunchSnapshot.decode(Data("{".utf8), session: "cmux-app-nx") == nil)
    }

    static let personalJSON = #"""
    {"personal_revision":4,"sessions":[],
     "profiles":[{"id":"default","name":"Default","index":0,"follows":[]},{"id":"prof_a","name":"Work","index":1,"follows":[]}],
     "pins":[],"groups":[{"id":"grp_1","profile":"prof_a","name":"G","collapsed":false,"index":0}],
     "workspaces":[{"session_id":"s1","workspace_key":"k2","index":0,"group":"grp_1"}]}
    """#

    /// Rooms and personal groups filter and group the sidebar, so the
    /// provisional tree carries them and the live one keeps the same models.
    @Test func thePersonalStateDrawsBeforeConnectingAndIsKeptLive() throws {
        let personal = try JSONDecoder().decode(JSONValue.self, from: Data(Self.personalJSON.utf8))
        let snapshot = try #require(LaunchSnapshot.decode(try Self.file(windows: nil, personal: personal), session: "cmux-app-nx"))
        #expect(snapshot.tree.personal?.revision == 4)
        #expect(snapshot.tree.personal?.groups.map(\.id) == ["grp_1"])
        // A file from an older daemon has none; the live read fills it.
        #expect(LaunchSnapshot.decode(try Self.file(windows: nil), session: "cmux-app-nx")?.tree.personal == nil)

        let store = DaemonStore()
        store.applyProvisional(snapshot: snapshot.tree)
        #expect(store.profiles.map(\.id) == ["default", "prof_a"])
        #expect(store.personal.isLoaded)
        let drawn = store.profiles.map(ObjectIdentifier.init)

        var live = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        live.personal = try JSONDecoder().decode(PersonalState.self, from: Data(Self.personalJSON.utf8))
        store.apply(snapshot: live)
        #expect(store.profiles.map(ObjectIdentifier.init) == drawn)
    }

    @Test func loadsFromDiskAndRefusesOversizedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("launch-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("launch-snapshot.json").path
        #expect(LaunchSnapshot.load(path: path, session: "cmux-app-nx") == nil, "a missing file shows nothing")
        try Self.file(windows: nil).write(to: URL(fileURLWithPath: path))
        #expect(LaunchSnapshot.load(path: path, session: "cmux-app-nx") != nil)
        try Data(count: LaunchSnapshot.maximumBytes + 1).write(to: URL(fileURLWithPath: path))
        #expect(LaunchSnapshot.load(path: path, session: "cmux-app-nx") == nil)
    }

    @Test func theHandshakeRemembersThePathPerSession() throws {
        let suite = "cmux-next-launch-snapshot-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        nonisolated(unsafe) let shared = defaults
        let location = LaunchSnapshotLocation(defaults: { shared })
        #expect(location.path(session: "cmux-app-nx") == nil)
        location.record("/state/launch-snapshot.json", session: "cmux-app-nx")
        #expect(location.path(session: "cmux-app-nx") == "/state/launch-snapshot.json")
        #expect(location.path(session: "cmux-app-other") == nil)
        location.record(nil, session: "cmux-app-nx")
        #expect(location.path(session: "cmux-app-nx") == nil)

        let identify = try Fixture.response(DaemonIdentity.self, "identify.json")
        #expect(identify.launchSnapshotPath == nil, "older daemons report no path")
        let reported = try JSONDecoder().decode(DaemonIdentity.self, from: Data(
            #"{"app":"cmux-tui","protocol":12,"generation":"g1","launch_snapshot_path":"/s/launch-snapshot.json"}"#.utf8))
        #expect(reported.launchSnapshotPath == "/s/launch-snapshot.json")
    }

    /// The provisional tree draws the same models the live tree then keeps:
    /// nothing is rebuilt when the layout did not change, and nothing that
    /// waits for the live tree runs from the snapshot.
    @Test func theLiveTreeReplacesTheProvisionalOneInPlace() throws {
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        let store = DaemonStore()
        var listChanges = 0
        store.onWorkspaceListChanged = { listChanges += 1 }
        store.applyProvisional(snapshot: tree)
        #expect(store.isProvisional)
        #expect(!store.isLoaded)
        #expect(listChanges == 0)
        #expect(store.workspaces.count == tree.workspaces.count)
        let drawn = store.workspaces.map(ObjectIdentifier.init)
        let drawnTabs = store.workspaces.flatMap { $0.screens.flatMap { $0.panes.flatMap { $0.tabs } } }.map(ObjectIdentifier.init)
        #expect(!drawnTabs.isEmpty)

        store.apply(snapshot: tree)
        #expect(!store.isProvisional)
        #expect(store.isLoaded)
        #expect(store.workspaces.map(ObjectIdentifier.init) == drawn)
        #expect(store.workspaces.flatMap { $0.screens.flatMap { $0.panes.flatMap { $0.tabs } } }.map(ObjectIdentifier.init) == drawnTabs)

        // A late snapshot never replaces the live tree.
        store.applyProvisional(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces-empty.json"))
        #expect(!store.isProvisional)
        #expect(store.workspaces.count == tree.workspaces.count)
    }
}

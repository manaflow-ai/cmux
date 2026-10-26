@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextLaunch
import Foundation
import Testing

/// The window the launch shows first has one rule (p08-startup-058): `WindowRegistry.restored(_:)`, which
/// `WindowRegistry(records:)` and `LaunchSnapshotWindow` both use, so the front window's picture read in `main` is
/// always the window the launch builds. Each fixture compares the rule with the registry's recency, the way
/// `LaunchSnapshotWindow.showSaved` picks it.
@MainActor
@Suite struct LaunchFrontWindowTests {
    nonisolated static func record(_ id: String, _ workspaces: [String], order: Int, closed: Bool = false, profile: ProfileID? = nil) -> WindowRecord {
        WindowRecord(id: id, workspaceKey: workspaces.first.map(WorkspaceKey.init(rawValue:)),
                     workspaceKeys: workspaces.map(WorkspaceKey.init(rawValue:)), order: order, profile: profile, isClosed: closed)
    }

    /// The window the registry built from `records` makes front: its recency's first with a mirrored workspace.
    static func registryFront(_ records: [WindowRecord], mirrors: (String) -> Bool) -> String? {
        let saved = WindowRegistry(records: records)
        return saved.recency.first { id in saved.window(id)?.workspaceIDs.contains(where: mirrors) == true }
    }

    nonisolated static func tree(_ keys: [String]) -> DaemonTree {
        DaemonTree(workspaces: keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key)
        })
    }

    nonisolated static let fixtures: [(name: String, records: [WindowRecord], mirrored: Set<String>, front: String?)] = [
        ("reordered", [record("back", ["b"], order: 2), record("front", ["a"], order: 0), record("middle", ["c"], order: 1)],
         ["a", "b", "c"], "front"),
        // A closed window keeps its workspaces and its place; the launch shows the front record's window.
        ("closed front", [record("closed", ["a"], order: 0, closed: true), record("open", ["b"], order: 1)], ["a", "b"], "closed"),
        ("every window closed", [record("one", ["a"], order: 0, closed: true), record("two", ["b"], order: 1, closed: true)],
         ["a", "b"], "one"),
        ("empty record", [record("empty", [], order: 0), record("full", ["a"], order: 1)], ["a"], "full"),
        // A further-front (closed) record owns the workspace an open record lists only: the open record goes.
        ("duplicate workspace", [record("closed", ["a"], order: 0, closed: true), record("open", ["a"], order: 1)], ["a"], "closed"),
        ("duplicate, partly", [record("first", ["a"], order: 0), record("second", ["a", "b"], order: 1)], ["b"], "second"),
        ("not mirrored", [record("gone", ["x"], order: 0), record("here", ["a"], order: 1)], ["a"], "here"),
        ("same id twice", [record("w", ["a"], order: 0), record("v", ["b"], order: 1), record("w", ["c"], order: 2)], ["c"], "w"),
        ("nothing mirrored", [record("w", ["a"], order: 0)], [], nil),
        ("no records", [], ["a"], nil),
    ]

    @Test(arguments: fixtures.indices)
    func theFrontRuleIsTheRegistrysRecency(_ index: Int) {
        let fixture = Self.fixtures[index]
        let mirrors = { fixture.mirrored.contains($0) }
        #expect(WindowRegistry.restored(fixture.records).map(\.id) == WindowRegistry(records: fixture.records).recency,
                "\(fixture.name): the restored order is not the registry's recency")
        let front = LaunchSnapshotWindow.front(of: fixture.records, mirrors: mirrors)?.id
        #expect(front == fixture.front, "\(fixture.name)")
        #expect(front == Self.registryFront(fixture.records, mirrors: mirrors), "\(fixture.name): the picture's window is not the launch's")
        let picked = LaunchSnapshotWindow.savedFront(windows: WindowStateDocument(windows: fixture.records), tree: Self.tree(Array(fixture.mirrored)))
        #expect(picked?.window == fixture.front, "\(fixture.name): the snapshot read picked another window")
    }

    /// The restored window keeps its records' workspaces as the registry does.
    @Test func restoredWindowsKeepTheRegistrysWorkspaces() {
        for fixture in Self.fixtures {
            let saved = WindowRegistry(records: fixture.records)
            for window in WindowRegistry.restored(fixture.records) {
                #expect(saved.window(window.id)?.workspaceIDs == window.workspaceIDs, "\(fixture.name): \(window.id)")
            }
        }
    }

    /// The picture's folder is the window's profile; a record with none shows the default profile.
    @Test func theFrontsProfileNamesThePicturesFolder() {
        let work = ProfileID(rawValue: "prof_0123456789abcdef0123456789abcdef")
        let records = [Self.record("w", ["a"], order: 0, profile: work), Self.record("v", ["b"], order: 1)]
        #expect(LaunchSnapshotWindow.savedFront(windows: WindowStateDocument(windows: records), tree: Self.tree(["a", "b"]))
                == WindowPictureStore.FrontWindow(window: "w", profile: work.rawValue))
        #expect(LaunchSnapshotWindow.savedFront(windows: WindowStateDocument(windows: records), tree: Self.tree(["b"]))
                == WindowPictureStore.FrontWindow(window: "v", profile: ProfileID.defaultProfile.rawValue))
    }

    /// No snapshot, or one without window records: no front window, so no picture is read.
    @Test func noSnapshotNoFront() throws {
        let state = FileManager.default.temporaryDirectory.appending(path: "launch-front-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let suite = "launch-front-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let location = LaunchSnapshotLocation(defaults: { UserDefaults(suiteName: suite) ?? .standard })
        #expect(LaunchSnapshotWindow.savedFront(session: "cmux-app-test", stateDirectory: state, location: location) == nil)
        #expect(LaunchSnapshotWindow.savedFront(session: "cmux-app-test", stateDirectory: nil, location: location) == nil)
        #expect(LaunchSnapshotWindow.savedFront(windows: nil, tree: Self.tree(["a"])) == nil)
    }
}

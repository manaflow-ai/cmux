import Foundation
@testable import CmuxNextDaemon
import Testing

/// The bare launch (piece 8 of hq `docs/design/launch-shell-first.md`; Leo, 2026-11-16: "i know we can at least start
/// up shells of stuff fresh"): with nothing to restore, the launch spares the work that exists for restored windows.
/// ``LaunchKind/bare`` is claimed only on evidence, because a missing snapshot alone also happens beside saved
/// windows (a file too large, of another schema or session, or one an older daemon never wrote).
@Suite struct LaunchKindTests {
    static func snapshot(workspaces: String) throws -> LaunchSnapshot {
        let file = #"{"schema_version":1,"session":"cmux-app","tree":{"workspaces":[\#(workspaces)]}}"#
        return try #require(LaunchSnapshot.decode(Data(file.utf8), session: "cmux-app"))
    }

    static let home = #"{"id":1,"name":"Home","kind":"home"}"#

    @Test func aSnapshotWithOnlyHomeAndNoWindowIsBare() throws {
        let snapshot = try Self.snapshot(workspaces: Self.home)
        #expect(LaunchKind.of(snapshot: snapshot, pathRecorded: true, registryExists: true) == .bare)
        #expect(LaunchKind.of(snapshot: try Self.snapshot(workspaces: ""), pathRecorded: true, registryExists: true) == .bare)
    }

    @Test func aSnapshotWithAWorkspaceOrAWindowIsNot() throws {
        let workspace = try Self.snapshot(workspaces: Self.home + #",{"id":2,"name":"repo"}"#)
        #expect(LaunchKind.of(snapshot: workspace, pathRecorded: true, registryExists: true) == .unknown)
        var window = try Self.snapshot(workspaces: Self.home)
        window.windows = WindowStateDocument(windows: [WindowRecord(id: "w1")])
        #expect(LaunchKind.of(snapshot: window, pathRecorded: true, registryExists: true) == .unknown)
    }

    @Test func noSnapshotIsBareOnlyInAFreshHome() {
        #expect(LaunchKind.of(snapshot: nil, pathRecorded: false, registryExists: false) == .bare)
        #expect(LaunchKind.of(snapshot: nil, pathRecorded: true, registryExists: false) == .unknown, "a handshake recorded a snapshot path: the daemon ran")
        #expect(LaunchKind.of(snapshot: nil, pathRecorded: false, registryExists: true) == .unknown, "the session has a registry the snapshot did not come from")
    }

    @Test func aRegistryIsFoundOnlyForItsOwnSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-kind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!LaunchSnapshotLocation.registryExists(session: "cmux-app", in: root), "a state directory that does not exist has none")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cmux-app-a-b"), withIntermediateDirectories: true)
        #expect(!LaunchSnapshotLocation.registryExists(session: "cmux-app", in: root), "cmux-app-a-b is another session's")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cmux-app-r1"), withIntermediateDirectories: true)
        #expect(LaunchSnapshotLocation.registryExists(session: "cmux-app", in: root))
    }

    @Test func withNoStateDirectoryTheDaemonsDefaultIsSearched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-kind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cmux-app-r1"), withIntermediateDirectories: true)
        #expect(LaunchSnapshotLocation.registryExists(session: "cmux-app", in: nil, environment: ["CMUX_TUI_STATE_DIR": root.path]))
        #expect(!LaunchSnapshotLocation.registryExists(session: "other", in: nil, environment: ["CMUX_TUI_STATE_DIR": root.path]))
    }
}

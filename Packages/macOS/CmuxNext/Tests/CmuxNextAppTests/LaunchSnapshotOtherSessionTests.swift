@testable import CmuxNextDaemon
import Foundation
import Testing

/// cmuxterm-hq#12660: the defaults (the account's, whatever the home) can name another session's launch snapshot.
/// It is told from this home's own before the daemon answers, from the registry id this home's last handshake
/// recorded, so the launch read gives no snapshot and its windows are never drawn, not even until the live tree
/// comes. This home's own snapshot is read as before (Leo, 2026-11-17: "my recently opened thing").
@Suite struct LaunchSnapshotOtherSessionTests {
    private nonisolated struct RegistryRequest: Encodable { var appSupport = "/nonexistent", session = "cmux-app" }
    private nonisolated struct RegistryReply: Decodable { var registryId: String? }

    /// Whether the app FFI answers `window_launch_current_registry` (the next release after its PR, once re-pinned).
    /// Nonisolated: `@Test(.enabled(if:))` reads it from a Sendable closure, off the suite's main actor.
    nonisolated static let ffiReadsTheRegistry =
        LaunchSnapshot.rule("window_launch_current_registry", RegistryRequest(), as: RegistryReply.self) != nil

    private func home() -> (LaunchSnapshotLocation, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-other-session-\(UUID().uuidString)")
        let suite = "launch-other-session-\(UUID().uuidString)"
        let location = LaunchSnapshotLocation(defaults: { UserDefaults(suiteName: suite) ?? UserDefaults() },
                                              applicationSupport: { root })
        return (location, root)
    }

    /// A snapshot file written by the daemon whose registry is `registry`, at the path the defaults name.
    private func snapshotFile(registry: String, in root: URL, location: LaunchSnapshotLocation) throws {
        let file = root.appendingPathComponent("state/cmux-app-1/launch-snapshot.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schema_version":1,"session":"cmux-app","tree":{"registry_id":"\#(registry)","workspaces":[]}}"#.utf8).write(to: file)
        location.record(file.path, session: "cmux-app")
    }

    @Test(.enabled(if: Self.ffiReadsTheRegistry, "the pinned app FFI predates window_launch_current_registry"))
    func anotherSessionsSnapshotIsNeverDrawn() throws {
        let (location, root) = home(); defer { try? FileManager.default.removeItem(at: root) }
        location.recordRegistry("registry-this-home", session: "cmux-app")
        try snapshotFile(registry: "registry-other-home", in: root, location: location)
        #expect(LaunchSnapshot.saved(session: "cmux-app", stateDirectory: nil, location: location) == nil)
    }

    @Test(.enabled(if: Self.ffiReadsTheRegistry, "the pinned app FFI predates window_launch_current_registry"))
    func thisHomesOwnSnapshotIsDrawn() throws {
        let (location, root) = home(); defer { try? FileManager.default.removeItem(at: root) }
        location.recordRegistry("registry-this-home", session: "cmux-app")
        try snapshotFile(registry: "registry-this-home", in: root, location: location)
        let read = try #require(LaunchSnapshot.saved(session: "cmux-app", stateDirectory: nil, location: location))
        #expect(read.tree.registryID == "registry-this-home")
        #expect(read.knownRegistryID == "registry-this-home")
        #expect(read.verdictBeforeConnect() == "current")
    }

    /// Before a handshake recorded a registry (the first launch with this build), the snapshot is read as before.
    @Test func noRecordedRegistryReadsTheSnapshot() throws {
        let (location, root) = home(); defer { try? FileManager.default.removeItem(at: root) }
        try snapshotFile(registry: "registry-any", in: root, location: location)
        let read = try #require(LaunchSnapshot.saved(session: "cmux-app", stateDirectory: nil, location: location))
        #expect(read.knownRegistryID == nil)
    }
}

import CmuxNextDaemon
import Foundation
import Testing

/// #17587: the launch snapshot is read on a background task begun in `main` (`DaemonPrestart`,
/// through `LaunchRead`, tested in CmuxNextLaunchTests' `LaunchReadTests`); `LaunchSnapshot.find` is that read.
@Suite struct LaunchSnapshotFindTests {
    @Test func theLaunchSnapshotOfASessionWithNoFileIsNone() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "launch-read-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "launch-read-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let location = LaunchSnapshotLocation(defaults: { UserDefaults(suiteName: suite) ?? .standard })
        guard case .none = LaunchSnapshot.find(session: "cmux-app-test", stateDirectory: directory, location: location) else {
            Issue.record("a session with no snapshot file found one")
            return
        }
    }
}

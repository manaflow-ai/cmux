import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation
import Testing

/// The daemon's launch snapshot is read and decoded off main. `main` begins the read on the files
/// lane (``LaunchSnapshotPrefetch``); the local daemon's start applies it in its own turn when the read has ended
/// first, else on the read's end, and the launch window opens on ``DaemonLaunchSnapshot/whenSettled(_:)``. Before,
/// `DaemonService.start` called `LaunchSnapshot.load` (up to 8 MiB of JSON) on the main thread.
@MainActor @Suite(.timeLimit(.minutes(1))) struct DaemonLaunchSnapshotTakeTests {
    static let session = "cmux-app-launch-snapshot-test"
    let work = BackgroundWork(label: "test.launch-snapshot")

    static func snapshot(_ names: [String]) -> LaunchSnapshot {
        let tree = DaemonTree(workspaces: names.enumerated().map { index, name in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: name), name: name)
        })
        return LaunchSnapshot(tree: tree, windows: WindowStateDocument(), session: session)
    }

    /// A service whose read-end hop runs on a later main turn, as the app's post does.
    func service() -> DaemonService {
        let service = DaemonService()
        service.launchSnapshot.hop = StartupMainHop { work in Task { @MainActor in work() } }
        return service
    }

    /// Suspends until the service's launch snapshot has settled.
    func settled(_ service: DaemonService) async {
        await withCheckedContinuation { continuation in service.launchSnapshot.whenSettled { continuation.resume() } }
    }

    /// The warm order: the read ended before the start, which applies it in its own turn, and the window opens then.
    @Test func aReadEndedBeforeTheStartAppliesInItsTurn() {
        let service = DaemonService()
        service.launchSnapshot.hop = StartupMainHop { _ in Issue.record("an ended read hopped to a later turn") }
        let read = SnapshotGate(ended: .snapshot(Self.snapshot(["a", "b"])))
        service.launchSnapshot.take(read.prefetch(Self.session), session: Self.session, stateDirectory: nil, work: work)
        var opened = false
        service.launchSnapshot.whenSettled { opened = true }
        #expect(opened, "the launch window waited for a read that had ended")
        #expect(service.store.isProvisional)
        #expect(service.store.workspaces.map(\.name) == ["a", "b"])
        #expect(service.launchSnapshot.windows != nil)
    }

    /// The cold order: the start comes first; nothing is applied until the read ends, then the snapshot applies and
    /// the waiting window opens drawn from it, in post order.
    @Test func aReadEndingAfterTheStartAppliesOnItsEnd() async {
        let service = service(), read = SnapshotGate()
        service.launchSnapshot.take(read.prefetch(Self.session), session: Self.session, stateDirectory: nil, work: work)
        var steps: [String] = []
        service.launchSnapshot.whenSettled { steps.append("window: provisional=\(service.store.isProvisional)") }
        #expect(steps.isEmpty, "the launch window opened before the snapshot's read ended")
        #expect(!service.store.isProvisional)
        read.end(.snapshot(Self.snapshot(["a"])))
        await settled(service)
        #expect(steps == ["window: provisional=true"])
        #expect(service.store.workspaces.map(\.name) == ["a"])
    }

    /// A read slower than the connect: the live tree came first and stays; the late snapshot is dropped.
    @Test func aSnapshotReadAfterTheLiveTreeIsDropped() async {
        let service = service(), read = SnapshotGate()
        service.launchSnapshot.take(read.prefetch(Self.session), session: Self.session, stateDirectory: nil, work: work)
        service.store.apply(snapshot: Self.snapshot(["live"]).tree)
        read.end(.snapshot(Self.snapshot(["stale"])))
        await settled(service)
        #expect(!service.store.isProvisional)
        #expect(service.store.workspaces.map(\.name) == ["live"])
        #expect(service.launchSnapshot.windows == nil)
    }

    /// No snapshot, or one that cannot be used: nothing is drawn and the window still opens.
    @Test(arguments: [LaunchSnapshot.Found.missing, .skipped(.otherSchema(2))])
    func nothingToDrawStillSettles(_ found: LaunchSnapshot.Found) async {
        let service = service(), read = SnapshotGate()
        service.launchSnapshot.take(read.prefetch(Self.session), session: Self.session, stateDirectory: nil, work: work)
        read.end(found)
        await settled(service)
        #expect(!service.store.isProvisional)
    }

    /// Without `main`'s read (or with one for another session) the start posts its own to the files lane: the
    /// file is never read in the start's turn.
    @Test func withoutAPrefetchTheStartReadsOnTheFilesLane() async throws {
        let state = FileManager.default.temporaryDirectory.appending(path: "launch-snapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let registry = state.appending(path: "\(Self.session)-1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try Data(#"{"schema_version":1,"session":"\#(Self.session)","tree":{}}"#.utf8).write(to: registry.appending(path: "launch-snapshot.json"))
        let suite = "launch-snapshot-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let service = service()
        service.launchSnapshot.location = LaunchSnapshotLocation(defaults: { UserDefaults(suiteName: suite) ?? .standard })
        let other = SnapshotGate(ended: .snapshot(Self.snapshot(["other session"])))
        service.launchSnapshot.take(other.prefetch("another-session"), session: Self.session, stateDirectory: state, work: work)
        #expect(!service.store.isProvisional, "the start read the snapshot in its own turn, or took another session's")
        await settled(service)
        #expect(service.store.isProvisional)
        #expect(service.store.workspaces.isEmpty)
    }

    /// `LaunchSnapshot.find`, the rule `main`'s read and the start's own read share: the remembered path first, else
    /// the newest in the state directory; nothing without either, and why a file was not used.
    @Test func findReadsTheRememberedPathElseTheStateDirectory() throws {
        let state = FileManager.default.temporaryDirectory.appending(path: "launch-snapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let registry = state.appending(path: "\(Self.session)-1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let suite = "launch-snapshot-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let location = LaunchSnapshotLocation(defaults: { UserDefaults(suiteName: suite) ?? .standard })
        guard case .missing = LaunchSnapshot.find(session: Self.session, stateDirectory: state, location: location) else {
            Issue.record("a state directory without a snapshot found one")
            return
        }
        let file = registry.appending(path: "launch-snapshot.json")
        try Data(#"{"schema_version":1,"session":"\#(Self.session)","tree":{}}"#.utf8).write(to: file)
        #expect(LaunchSnapshot.find(session: Self.session, stateDirectory: state, location: location).snapshot != nil)
        let remembered = state.appending(path: "remembered.json")
        try Data(#"{"schema_version":2,"session":"\#(Self.session)","tree":{}}"#.utf8).write(to: remembered)
        location.record(remembered.path, session: Self.session)
        guard case .skipped(.otherSchema(2)) = LaunchSnapshot.find(session: Self.session, stateDirectory: state, location: location) else {
            Issue.record("the remembered path did not go first")
            return
        }
    }
}

/// A launch snapshot read the test ends by hand.
nonisolated final class SnapshotGate: Sendable {
    private struct State {
        var found: LaunchSnapshot.Found?
        var waiters: [CheckedContinuation<LaunchSnapshot.Found, Never>] = []
    }

    private let state: Mutex<State>

    init(ended found: LaunchSnapshot.Found? = nil) {
        state = Mutex(State(found: found))
    }

    func prefetch(_ session: String) -> LaunchSnapshotPrefetch {
        LaunchSnapshotPrefetch(session: session, ended: { [self] in state.withLock { $0.found } }, finished: { [self] in await finished() })
    }

    func end(_ found: LaunchSnapshot.Found) {
        let waiters = state.withLock { state in
            state.found = found
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: found) }
    }

    private func finished() async -> LaunchSnapshot.Found {
        await withCheckedContinuation { (continuation: CheckedContinuation<LaunchSnapshot.Found, Never>) in
            let found = state.withLock { state -> LaunchSnapshot.Found? in
                if state.found == nil { state.waiters.append(continuation) }
                return state.found
            }
            if let found { continuation.resume(returning: found) }
        }
    }
}

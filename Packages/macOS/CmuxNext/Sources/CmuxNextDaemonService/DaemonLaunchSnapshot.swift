public import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import os

/// The local daemon's launch snapshot (`launch-snapshot-v1`, plans/cmux-next/cmux-tui-contract.md) for one service:
/// the last layout, applied to the store as a provisional tree so the first frame shows it instead of the connecting
/// state, then replaced in place by the live tree.
///
/// The main thread never reads or decodes the file (up to 8 MiB of JSON). `main` begins the read on
/// the files lane (``LaunchSnapshotPrefetch``); ``take(_:session:stateDirectory:work:)`` applies it in its own turn
/// when the read has ended, else on the read's end, posted to main as userBlocking work (Chrome replies to the UI
/// thread with the result, `PostTaskAndReplyWithResult`, base/task/task_runner.h; it never waits for it there).
/// A snapshot read after the live tree arrived is dropped: the live tree is what the window shows.
///
/// ```swift
/// daemon.launchSnapshot.whenSettled { openLaunchWindow() }   // drawn from the snapshot when there is one
/// ```
public final class DaemonLaunchSnapshot {
    /// The window records of the snapshot, drawn before the first connection (`LaunchSnapshotWindow`); nil without one.
    public private(set) var windows: WindowStateDocument?
    /// The local session whose launch snapshot path each handshake records.
    var session: String?
    var location = LaunchSnapshotLocation()
    /// How a read that ended off main reaches main (a test runs it by hand).
    var hop: StartupMainHop
    /// Asked on the files lane before a read ``take(_:session:stateDirectory:work:)`` posts: false reads nothing and
    /// shows no snapshot (the app's crash-streak safe launch, `LaunchSafeMode`; its `main` gates its own prefetch).
    public var reads: @Sendable () -> Bool = { true }
    /// The steps waiting for a running read (``whenSettled(_:)``); nil while none runs.
    private var waiters: [() -> Void]?
    private let store: DaemonStore
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.daemon")

    /// - Parameters:
    ///   - store: The service's store, which shows the snapshot as its provisional tree.
    ///   - mainWork: Where a read that ends off main posts its apply (userBlocking).
    init(store: DaemonStore, mainWork: MainWorkScheduler) {
        self.store = store
        hop = StartupMainHop { work in mainWork.postFromAnyThread(.userBlocking, owner: "DaemonService.launchSnapshot", work) }
    }

    /// Applies `session`'s snapshot: `prefetch`'s when it reads `session`'s, else a read this posts to `work`'s files
    /// lane (`LaunchSnapshot.find`: the last handshake's path, else the newest in `stateDirectory`). A missing, stale
    /// or unreadable file shows nothing.
    func take(_ prefetch: LaunchSnapshotPrefetch?, session: String, stateDirectory: URL?, work: BackgroundWork) {
        self.session = session
        let read = prefetch?.session == session ? prefetch : nil
        if let found = read?.found { return apply(found) }
        waiters = waiters ?? []
        let hop = self.hop, location = self.location, reads = self.reads
        let applyOnMain: @MainActor @Sendable (LaunchSnapshot.Found) -> Void = { [weak self] found in self?.apply(found) }
        if let read {
            work.task(.userBlocking) {
                let found = await read.result()
                hop.later { applyOnMain(found) }
            }
            return
        }
        work.post(.userBlocking, mayBlock: .files, abandoned: { hop.later { applyOnMain(LaunchSnapshot.Found.missing) } }) {
            let found = reads() ? LaunchSnapshot.find(session: session, stateDirectory: stateDirectory, location: location) : .missing
            hop.later { applyOnMain(found) }
        }
    }

    /// Holds ``whenSettled(_:)`` steps for a ``take(_:session:stateDirectory:work:)`` still to come: the app starts its
    /// local daemon once its system-lane launch step lands (`AppServices.startLocalDaemon(after:)`), and the launch
    /// window must not open before the snapshot that start applies. ``endExpectedTake()`` releases them when the
    /// start made no take. Nothing once a take was made.
    public func expectTake() {
        guard session == nil, waiters == nil else { return }
        waiters = []
    }

    /// Runs the steps ``expectTake()`` held when the start ended without a take (its launcher could not be made).
    public func endExpectedTake() {
        guard session == nil else { return }
        settle()
    }

    /// Runs `step` once the snapshot is applied or known to be missing: at once when no read runs (it ended before
    /// `start`, or none started), else on the read's end, in post order. The launch window opens here, so it is
    /// drawn from the snapshot instead of showing the connecting state for a frame.
    public func whenSettled(_ step: @escaping () -> Void) {
        guard waiters != nil else { return step() }
        waiters?.append(step)
    }

    /// Records the snapshot path the local daemon reported, for the next launch.
    func remember(_ identity: DaemonIdentity) {
        guard let session, identity.session == session else { return }
        location.record(identity.launchSnapshotPath, session: session)
    }

    private func apply(_ found: LaunchSnapshot.Found) {
        defer { settle() }
        switch found {
        case .missing:
            return
        case .skipped(let skip):
            logger.error("launch snapshot skipped: \(String(describing: skip), privacy: .public)")
        case .snapshot(let snapshot):
            guard !store.isLoaded else { return }
            store.applyProvisional(snapshot: snapshot.tree)
            windows = snapshot.windows
            DaemonService.launchMark("launch_snapshot_applied")
        }
    }

    private func settle() {
        guard let waiting = waiters else { return }
        waiters = nil
        for step in waiting { step() }
    }
}

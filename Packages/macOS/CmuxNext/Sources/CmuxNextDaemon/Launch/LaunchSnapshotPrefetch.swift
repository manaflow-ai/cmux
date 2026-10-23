public import Foundation
import CmuxNextCompat

/// The launch snapshot read and decoded off the main thread, begun with the daemon prestart at
/// the top of `main`, so the file read and the JSON decode overlap AppKit's start instead of
/// running inside `applicationDidFinishLaunching` before the first window (#17587). The main
/// thread takes the result when it builds the launch window; a read still running then is not
/// waited for: the main thread reads the file itself, as it did before, and the late result is
/// dropped. So a launch is never slower than reading on the main thread.
public final class LaunchSnapshotPrefetch: Sendable {
    /// What reading a session's launch snapshot found.
    public enum Outcome: Sendable {
        /// No snapshot file for the session (a first launch, or the path was never recorded).
        case none
        /// The decoded snapshot.
        case read(LaunchSnapshot)
        /// A file that was not used, and why (the launch shows the connecting state).
        case skipped(LaunchSnapshot.Skip)
    }

    private enum State {
        case reading
        case done(Outcome)
        case taken
    }

    // One-shot hand-off between the reading task and the main thread's single `take()`: a
    // synchronous take must never wait on the reader, so an actor (an await) cannot serve it.
    private let state = Mutex(State.reading)
    private let session: String
    private let stateDirectory: URL?
    private let location: LaunchSnapshotLocation

    /// Starts reading `session`'s launch snapshot now, on a background task.
    /// - Parameters:
    ///   - session: The daemon session whose snapshot to read.
    ///   - stateDirectory: The daemon's state directory, searched when the defaults lost the path.
    ///   - location: Where the last handshake recorded the snapshot path.
    public init(session: String, stateDirectory: URL?, location: LaunchSnapshotLocation = LaunchSnapshotLocation()) {
        self.session = session
        self.stateDirectory = stateDirectory
        self.location = location
        // task-owner: one read per launch, bounded by the file's size cap (`LaunchSnapshot.maximumBytes`)
        Task.detached(priority: .userInitiated) { [self] in
            let outcome = Self.read(session: session, stateDirectory: stateDirectory, location: location)
            state.withLock { state in
                if case .reading = state { state = .done(outcome) }
            }
        }
    }

    /// The prefetched outcome when the read finished, else the outcome of reading now on the
    /// caller's thread. Call once: the launch window takes it.
    public func take() -> Outcome {
        let ready = state.withLock { state -> Outcome? in
            defer { state = .taken }
            if case .done(let outcome) = state { return outcome }
            return nil
        }
        if let ready { return ready }
        // The read still ran: this thread reads it again (#17587's launch guard counts it).
        if Thread.isMainThread { DaemonLaunchTimings.shared.mark("launch_read_on_main.launch_snapshot") }
        return Self.read(session: session, stateDirectory: stateDirectory, location: location)
    }

    /// Reads and decodes `session`'s launch snapshot, and marks `launch_snapshot_read` when a file
    /// was read (`DaemonLaunchTimings`, from any thread).
    public static func read(session: String, stateDirectory: URL?, location: LaunchSnapshotLocation) -> Outcome {
        guard let path = location.path(session: session) ?? LaunchSnapshotLocation.find(session: session, in: stateDirectory) else {
            return .none
        }
        do throws(LaunchSnapshot.Skip) {
            let snapshot = try LaunchSnapshot.load(path: path, session: session)
            DaemonLaunchTimings.shared.mark("launch_snapshot_read")
            return .read(snapshot)
        } catch {
            return .skipped(error)
        }
    }
}

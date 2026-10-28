import Foundation

/// Keeps the run's ``CrashContext`` in the run marker, so a crash report of
/// this run can say what it was doing.
///
/// Event driven, no timer: an action run takes a snapshot at once when none
/// was taken in the last ``interval`` (a crash right after the action still
/// has it), else one when the interval ends (one pending at a time). An idle
/// app writes nothing.
///
/// ```swift
/// let recorder = CrashContextRecorder(snapshot: { services.crashContext() },
///                                     write: { marker.record(context: $0) })
/// recorder.start(actionBudget.samples(everyRun: true))
/// ```
@MainActor
public final class CrashContextRecorder {
    /// Takes a snapshot.
    public typealias Snapshot = @MainActor () -> CrashContext
    /// Stores one.
    public typealias Write = @MainActor (CrashContext) -> Void

    /// The shortest time between two snapshots.
    public let interval: Duration
    private let clock: any Clock<Duration>
    private let snapshot: Snapshot
    private let write: Write
    private var listening: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var lastRecord: ContinuousClock.Instant?

    /// - Parameters:
    ///   - interval: The shortest time between two snapshots; one second by default.
    ///   - clock: Times the trailing snapshot (tests pass their own).
    ///   - snapshot: Takes the snapshot.
    ///   - write: Stores it.
    public init(interval: Duration = .seconds(1), clock: any Clock<Duration> = ContinuousClock(),
                snapshot: @escaping Snapshot, write: @escaping Write) {
        self.interval = interval
        self.clock = clock
        self.snapshot = snapshot
        self.write = write
    }

    /// Records on every element `runs` yields (one per action run), until ``stop()``.
    ///
    /// - Parameter runs: The action runs.
    public func start<Element: Sendable>(_ runs: AsyncStream<Element>) {
        listening?.cancel()
        listening = Task { [weak self] in  // task-owner: stored in listening, cancelled in stop()
            for await _ in runs { self?.actionRan() }
        }
    }

    /// Stops listening and drops a pending snapshot.
    public func stop() {
        listening?.cancel()
        pending?.cancel()
        listening = nil
        pending = nil
    }

    /// One action ran: a snapshot now, or one at the end of the interval.
    public func actionRan() {
        let now = ContinuousClock.now
        guard let last = lastRecord, now - last < interval else { return record(at: now) }
        guard pending == nil else { return }
        let wait = interval - (now - last)
        pending = Task { [weak self, clock] in  // task-owner: stored in pending, cancelled in stop()
            // wakeup-allow: one bounded trailing snapshot after an action burst; cancelled with the recorder.
            do { try await clock.sleep(for: wait) } catch { return }
            self?.pending = nil
            self?.record(at: .now)
        }
    }

    /// Takes and stores a snapshot now.
    ///
    /// - Parameter now: When, for the interval.
    public func record(at now: ContinuousClock.Instant = .now) {
        lastRecord = now
        write(snapshot())
    }
}

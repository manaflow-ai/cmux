import CmuxNextCompat
public import CmuxNextSignposts
public import CoreFoundation

/// The commit boundary ``InputLatencyTracker`` arms once per turn that opened a slot: it calls back after the Core
/// Animation commit that ends the turn, as ``CommitBoundary`` does. Tests pass a fake that fires on demand.
@MainActor
public protocol InputTurnBoundary: AnyObject {
    /// Sets the one handler every armed boundary calls. Called once, by the tracker's `init`.
    func start(_ handler: @escaping @MainActor (CommitBoundary.Outcome) -> Void)

    /// Asks for one call of the handler after the commit that ends this turn; arming again before it fires does
    /// nothing. Allocates nothing.
    func arm()
}

/// ``CommitBoundary`` made once: two repeating main run-loop observers, made at ``start(_:)`` and armed by a flag,
/// so a turn that tracks input allocates nothing (``CommitBoundary`` makes a new `CFRunLoopObserver` per call).
///
/// One observer runs first in each commit pass (before waiting or on exit, order `CFIndex.min`), counting the pass,
/// and first after each wake. The other runs right after Core Animation's commit (``CommitBoundary/order``) and fires
/// an armed boundary as ``CommitBoundary`` would: ``CommitBoundary/Outcome/committed`` at the end of the first commit
/// pass that began after ``arm()``. An arm inside a commit pass (from a commit observer, or from the handler itself)
/// misses that pass's commit: it fires at the next one, or with ``CommitBoundary/Outcome/missed`` when the run loop
/// slept and woke first.
@MainActor
public final class InputCommitObserver: InputTurnBoundary {
    private var handler: (@MainActor (CommitBoundary.Outcome) -> Void)?
    private var observers: [MainRunLoopObserver] = []
    private var armed = false
    /// Commit passes begun so far.
    private var pass: UInt64 = 0
    /// A commit pass began and the run loop has not woken since.
    private var inCommitPass = false
    /// The arm came inside commit pass ``armedPass``, so that pass's commit is not its own.
    private var armedLate = false
    private var armedPass: UInt64 = 0

    private let mode: CFRunLoopMode

    /// - Parameter mode: The run loop modes to observe: the common modes (Core Animation's commit runs in them), or
    ///   a private mode in tests, so no other main-queue work runs in the turns they drive.
    public init(mode: CFRunLoopMode = .commonModes) {
        self.mode = mode
    }

    public func start(_ handler: @escaping @MainActor (CommitBoundary.Outcome) -> Void) {
        self.handler = handler
        guard observers.isEmpty else { return }
        let activities: CFRunLoopActivity = [.beforeWaiting, .exit, .afterWaiting]
        observers = [
            MainRunLoopObserver(activities: activities, order: CFIndex.min, mode: mode) { [weak self] activity in
                if activity == .afterWaiting { self?.woke() } else { self?.commitPassBegan() }
            },
            MainRunLoopObserver(activities: activities, order: CommitBoundary.order, mode: mode) { [weak self] in
                self?.observed($0)
            },
        ]
    }

    // perf-hot: 0.05us key-dispatch
    public func arm() {
        guard !armed else { return }
        armed = true
        armedLate = inCommitPass
        armedPass = pass
    }

    /// The first observer of a commit pass ran (tests drive it directly).
    func commitPassBegan() {
        pass &+= 1
        inCommitPass = true
    }

    /// The run loop woke: arms from here on belong to the new turn (tests drive it directly).
    func woke() {
        inCommitPass = false
    }

    /// The observer after Core Animation's commit ran for `activity` (tests drive it directly).
    func observed(_ activity: CFRunLoopActivity) {
        if activity == .afterWaiting {
            if armed, armedLate { fire(.missed) }
            return
        }
        guard armed, !(armedLate && armedPass == pass) else { return }
        fire(.committed)
    }

    private func fire(_ outcome: CommitBoundary.Outcome) {
        armed = false
        armedLate = false
        handler?(outcome)
    }
}

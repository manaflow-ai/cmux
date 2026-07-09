import Foundation

/// Coordinates cancellation with `Process.run()`: Foundation raises an
/// Objective-C exception if termination APIs touch a task before launch.
/// `@unchecked Sendable` is safe here because all mutable state is protected by `lock`.
public final class ProcessTerminationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didLaunch = false
    private var didFinish = false
    private var terminationRequested = false

    /// Creates a gate in the pre-launch state.
    public init() {}

    /// Records a termination request. Returns `true` when the process has already
    /// launched (so the caller should terminate it now); `false` if it has not
    /// launched yet or has already finished.
    public func requestTermination() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return false }
        terminationRequested = true
        return didLaunch
    }

    /// Marks the process launched. Returns `true` when termination was already
    /// requested while the process was pre-launch (so the caller should terminate
    /// it now); `false` if no termination is pending or the process has finished.
    public func markLaunched() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return false }
        didLaunch = true
        return terminationRequested
    }

    /// Marks the process finished; subsequent launch/termination requests are no-ops.
    public func markFinished() {
        lock.lock()
        defer { lock.unlock() }
        didFinish = true
    }
}

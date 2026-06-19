import Foundation

/// Tracks whether `applicationDidFinishLaunching` has run, so app-icon work is
/// deferred until launch completes.
///
/// On Tahoe, touching `NSApplication.applicationIconImage` or
/// `effectiveAppearance` during `App.init()` can crash or wedge the process, so
/// the applier and appearance observer both gate on this flag and replay once
/// launch begins. The app target flips it from `applicationDidFinishLaunching`.
///
/// Isolation: a `Sendable` reference type guarded by an `NSLock` rather than an
/// actor — the flag is read synchronously from non-async launch/apply paths
/// (`AppIconApplier.apply`, the appearance observer) that cannot `await`, and it
/// is a single `Bool` set exactly once. A lock over a one-bit value read by
/// synchronous callers is the sanctioned shape; an actor would force those
/// synchronous readers onto suspension points they do not have.
public final class AppIconLaunchPhaseReporter: Sendable {
    private nonisolated(unsafe) var didFinishLaunching = false
    private let lock = NSLock()

    /// Creates a reporter that has not yet observed launch completion.
    public init() {}

    /// Records that `applicationDidFinishLaunching` has run.
    public func markDidFinishLaunching() {
        lock.lock()
        defer { lock.unlock() }
        didFinishLaunching = true
    }

    /// Whether `applicationDidFinishLaunching` has run.
    public func isApplicationFinishedLaunching() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFinishLaunching
    }
}

import CmuxNextCompatAppKit
import QuartzCore

/// Runs work right after the current Core Animation transaction committed.
protocol ChromiumHostCommitObserving {
    func afterCommit(_ body: @escaping @MainActor () -> Void)
}

/// The completion of a transaction nested in the turn's: Core Animation runs it on the main thread
/// once the outermost transaction committed (it adds no animation, so nothing makes it wait). A
/// run-loop observer would miss the commit of a resize made inside AppKit's display cycle, which
/// runs in Core Animation's own commit observer.
struct ChromiumHostTransactionCommits: ChromiumHostCommitObserving {
    func afterCommit(_ body: @escaping @MainActor () -> Void) {
        CATransaction.begin()
        CATransaction.setMainCompletion(body)
        CATransaction.commit()
    }
}

/// Runs work on the main thread after a delay (``ChromiumHostWakeUpDeadlines`` in the app; tests fire it).
protocol ChromiumHostFenceDeadlines {
    func after(_ delay: Duration, _ body: @escaping @MainActor @Sendable () -> Void)
}

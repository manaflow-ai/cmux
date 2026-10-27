import CmuxNextWakeups

/// The turns a test scheduler queued (``screenshotsTestWork(turns:)``).
@MainActor final class QueuedTurns {
    var count = 0
}

/// A main-thread scheduler with no display link whose posted turns run as main-actor tasks (tests): a model's
/// posted landing (``ScreenshotsModel``'s finished read) runs once the test awaits, with no main run loop pass.
/// `turns` counts the turns it queued, so a test sees that a read landed as a posted task.
@MainActor func screenshotsTestWork(turns: QueuedTurns = QueuedTurns()) -> MainWorkScheduler {
    MainWorkScheduler.testing(ledger: WakeupLedger(), performTurn: { turn in
        turns.count += 1
        Task { @MainActor in turn() }
    }) { _ in nil }
}

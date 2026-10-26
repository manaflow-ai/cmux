public import CmuxNextWakeups

extension MainWorkScheduler {
    /// A test scheduler on a link that never fires, with its own ledger: for fixtures that need
    /// the app's scheduler (a `TabContentCache`) and run no frame.
    public static func still() -> MainWorkScheduler {
        .testing(clock: ManualClock(), ledger: WakeupLedger()) { _ in StillTestLink() }
    }
}

@MainActor
private final class StillTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

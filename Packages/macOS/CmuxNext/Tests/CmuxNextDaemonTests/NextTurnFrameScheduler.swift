@testable import CmuxNextDaemon

/// A store driver's frame scheduler with no display link (tests): the drain runs on the next main-actor turn,
/// which still coalesces every event that arrived in between. The app passes its frame batcher
/// (`DaemonService.drainScheduler`).
struct NextTurnFrameScheduler: FrameBatchScheduler {
    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        // task-owner: the frame hop itself; runs once
        Task { @MainActor in work() }
    }
}

extension DaemonStore {
    /// ``run(connection:scheduler:)`` on the next-turn scheduler (tests with no app).
    func run(connection: DaemonConnection) async {
        await run(connection: connection, scheduler: NextTurnFrameScheduler())
    }
}

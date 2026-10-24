import CmuxNextWakeupsTestSupport

/// An actor on a ``ManualSerialExecutor`` of its own: ManualSerialExecutorTests give its turns, and
/// no other suite shares them.
actor ExecutorTestActor {
    static let shared = ExecutorTestActor()
    static let executor = ManualSerialExecutor()

    nonisolated var unownedExecutor: UnownedSerialExecutor { Self.executor.asUnownedSerialExecutor() }

    func run(_ body: @Sendable () -> Void) {
        body()
    }
}

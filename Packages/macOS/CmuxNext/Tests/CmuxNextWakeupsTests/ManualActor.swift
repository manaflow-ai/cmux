import CmuxNextWakeupsTestSupport

/// A global actor on a ``ManualSerialExecutor``: a deadline's action isolated to it runs only when
/// the test runs the executor's jobs (``DemandTimerTests`` is serialized: one test at a time).
@globalActor
actor ManualActor {
    static let shared = ManualActor()
    static let executor = ManualSerialExecutor()

    nonisolated var unownedExecutor: UnownedSerialExecutor { Self.executor.asUnownedSerialExecutor() }
}

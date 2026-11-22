/// `work`'s answer, or `fallback` once `deadline` passes, without waiting for `work` to stop: a call that does not stop
/// on cancel (an install-token mint) is still bounded, where a task group would wait for its child. The late work is
/// cancelled and its answer dropped. The same race as the carrier's token read (``CloudCarrierServe/race(_:_:)``).
public nonisolated struct CloudFirstAnswer {
    public nonisolated init() {}
    public static func value<T: Sendable>(within deadline: Duration, otherwise fallback: T,
                                          _ work: @escaping @Sendable () async -> T) async -> T {
        await CloudCarrierServe.race(deadline, work) ?? fallback
    }
}

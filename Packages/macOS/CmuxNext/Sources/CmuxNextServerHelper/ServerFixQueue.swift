/// Runs helper requests one at a time, in arrival order of `serially` calls.
actor FixQueue {
    private var tail: Task<Void, Never>?

    func serially<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task { () -> T in
            await previous?.value
            return await body()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }
}

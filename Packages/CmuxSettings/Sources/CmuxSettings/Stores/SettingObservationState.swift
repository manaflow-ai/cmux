actor SettingObservationState<Value: Sendable & Equatable> {
    private var lastYielded: Value?
    private var isRefreshing = false
    private var needsRefresh = false

    func refresh(
        read: @escaping @Sendable () async -> Value,
        to continuation: AsyncStream<Value>.Continuation
    ) async {
        if isRefreshing {
            needsRefresh = true
            return
        }
        isRefreshing = true
        while true {
            needsRefresh = false
            let value = await read()
            if needsRefresh { continue }
            if lastYielded != value {
                lastYielded = value
                continuation.yield(value)
            }
            if needsRefresh { continue }
            isRefreshing = false
            return
        }
    }
}

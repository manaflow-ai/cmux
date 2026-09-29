extension CloudSystemVPNOperationGate {
    @MainActor
    struct Operation<T: Sendable> {
        let acquired: Task<Void, Never>
        let result: Task<T, any Error>
        private let current: Task<T, any Error>
        private let state: State
        private let turn: Turn
        private let abandon: @MainActor () -> Void

        init(
            acquired: Task<Void, Never>,
            result: Task<T, any Error>,
            current: Task<T, any Error>,
            state: State,
            turn: Turn,
            abandon: @escaping @MainActor () -> Void
        ) {
            self.acquired = acquired
            self.result = result
            self.current = current
            self.state = state
            self.turn = turn
            self.abandon = abandon
        }

        func cancelIfPending() {
            guard !state.acquired, !state.finished else { return }
            state.cancelledBeforeAcquisition = true
            current.cancel()
        }

        @discardableResult
        func abandonIfAcquired(
            after grace: Duration,
            onCancellation: @escaping @MainActor () -> Void
        ) -> Bool {
            guard state.acquired, !state.finished else { return false }
            let hardGrace = max(grace, .seconds(1))
            state.abandonmentTask = Task { @MainActor in
                do {
                    try await ContinuousClock().sleep(for: grace)
                } catch {
                    return
                }
                guard !state.finished else { return }
                state.cancellationRequested = true
                onCancellation()
                current.cancel()
                do {
                    try await ContinuousClock().sleep(for: hardGrace)
                } catch {
                    return
                }
                guard !state.finished else { return }
                abandon()
            }
            return true
        }
    }
}

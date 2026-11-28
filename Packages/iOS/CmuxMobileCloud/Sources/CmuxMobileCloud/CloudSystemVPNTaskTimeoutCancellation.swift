extension CloudSystemVPNTaskTimeout {
    actor Cancellation<T: Sendable> {
        private var continuation: AsyncThrowingStream<T, any Error>.Continuation?
        private var isCancelled = false

        func install(
            _ continuation: AsyncThrowingStream<T, any Error>.Continuation,
            race: Race
        ) {
            self.continuation = continuation
            if isCancelled {
                finishCancellation(continuation, race: race)
            }
        }

        func cancel(race: Race) {
            isCancelled = true
            guard let continuation else { return }
            finishCancellation(continuation, race: race)
        }

        private func finishCancellation(
            _ continuation: AsyncThrowingStream<T, any Error>.Continuation,
            race: Race
        ) {
            Task {
                guard await race.win() else { return }
                continuation.finish(throwing: CancellationError())
            }
        }
    }
}

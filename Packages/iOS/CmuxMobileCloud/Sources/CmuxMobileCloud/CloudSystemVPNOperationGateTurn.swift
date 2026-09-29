extension CloudSystemVPNOperationGate {
    @MainActor
    final class Turn {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }

        func release() {
            guard !released else { return }
            released = true
            continuation?.resume()
            continuation = nil
        }
    }
}

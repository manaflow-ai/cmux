/// Serializes relay-credential rotation ownership across autopilot lifecycles.
/// An old broker request may finish after its task is cancelled, so the
/// endpoint checks this actor before every live endpoint mutation.
enum IrxRelayCredentialMutationResult: Sendable {
    case success
    case failure(String)
}

actor IrxRelayCredentialRotationGate {
    private var generation: UInt64 = 0
    private var mutationInFlight = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    func invalidate() async {
        if mutationInFlight {
            await withCheckedContinuation { continuation in
                mutationWaiters.append(continuation)
            }
        }
        generation &+= 1
    }

    func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        generation == expectedGeneration
    }

    /// Serializes the native endpoint mutation with lifecycle invalidation.
    /// Invalidation waits for an already-started insertRelay to finish, so the
    /// insert is either completed under the old lifecycle or never begins.
    func withCurrentMutation<Value: Sendable>(
        _ expectedGeneration: UInt64,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        guard generation == expectedGeneration, !mutationInFlight else { return nil }
        mutationInFlight = true
        let value = await operation()
        mutationInFlight = false
        let waiters = mutationWaiters
        mutationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        return value
    }
}

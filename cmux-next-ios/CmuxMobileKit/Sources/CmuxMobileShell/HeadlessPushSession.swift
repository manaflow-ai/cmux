import Observation

/// Owns the coordinator shared by overlapping cold background notification replies.
/// Kept separate from notification presentation so its lifetime can be exercised
/// without an account, keychain or network connection.
@MainActor @Observable
final class HeadlessPushSession<Coordinator: AnyObject & Sendable> {
    private(set) var running = false
    @ObservationIgnored private var count = 0
    @ObservationIgnored private var coordinator: Coordinator?

    func withCoordinator(
        create: @escaping @MainActor () async -> Coordinator?,
        stop: @MainActor (Coordinator) -> Void,
        deliver: @MainActor (Coordinator?) async -> Void
    ) async {
        count += 1
        running = true
        defer {
            count -= 1
            if count == 0 {
                if let coordinator { stop(coordinator) }
                coordinator = nil
                running = false
            }
        }
        if coordinator == nil { coordinator = await create() }
        await deliver(coordinator)
    }
}

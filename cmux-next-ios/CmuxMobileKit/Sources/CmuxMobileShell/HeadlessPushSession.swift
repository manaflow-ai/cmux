import Observation

/// Owns the coordinator shared by overlapping cold background notification replies.
/// Kept separate from notification presentation so its lifetime can be exercised
/// without an account, keychain or network connection.
@MainActor @Observable
final class HeadlessPushSession<Coordinator: AnyObject & Sendable> {
    private(set) var running = false
    @ObservationIgnored private var count = 0
    @ObservationIgnored private var coordinator: Coordinator?
    @ObservationIgnored private var creation: Task<Coordinator?, Never>?

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
                creation = nil
                running = false
            }
        }
        // Publish the task before suspending: another reply can enter while
        // account restoration or team loading is awaiting its result. Keep a
        // completed nil result until the batch ends too, so failure is shared.
        let pending: Task<Coordinator?, Never>
        if let creation {
            pending = creation
        } else {
            pending = Task { await create() }
            creation = pending
        }
        coordinator = await pending.value
        await deliver(coordinator)
    }
}

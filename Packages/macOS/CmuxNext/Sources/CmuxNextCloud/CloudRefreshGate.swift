import Foundation

/// Shares overlapping Cloud refresh triggers and keeps one latest follow-up.
/// CloudService is main-actor isolated, so the gate needs no additional lock.
@MainActor
final class CloudRefreshGate {
    private var active: Task<Void, Never>?
    private var followUpRequested = false

    func run(_ operation: @escaping @MainActor () async -> Void) async {
        if let active {
            followUpRequested = true
            await active.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.followUpRequested = false
            await operation()
            // concurrency-allow: this second pass follows an awaited refresh and only runs when a caller arrived during that await.
            if self.followUpRequested {
                self.followUpRequested = false
                await operation()
            }
        }
        active = task
        await task.value
        active = nil
    }
}

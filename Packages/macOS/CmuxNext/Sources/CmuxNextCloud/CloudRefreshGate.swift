import Foundation

/// Shares overlapping Cloud refresh triggers and keeps one latest follow-up.
/// CloudService is main-actor isolated, so the gate needs no additional lock.
@MainActor
public final class CloudRefreshGate {
    private var active: Task<Bool, Never>?
    private var followUpRequested = false

    public init() {}

    @discardableResult
    public func run(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
        if let active {
            followUpRequested = true
            return await active.value
        }

        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            self.followUpRequested = false
            var result = await operation()
            // concurrency-allow: this second pass follows an awaited refresh and only runs when a caller arrived during that await.
            while self.followUpRequested {
                self.followUpRequested = false
                result = await operation()
            }
            return result
        }
        active = task
        let result = await task.value
        active = nil
        return result
    }
}

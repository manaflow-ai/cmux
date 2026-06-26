import Foundation

/// In-flight registry of one-shot connection-readiness waiters for a single
/// tmux control connection.
///
/// Each waiter is a `(Bool) -> Void` callback keyed by an opaque `UUID` token,
/// registered while the connection is still `.connecting`/`.reconnecting` and
/// resumed exactly once with the terminal verdict (`true` on `.connected`,
/// `false` on `.ended` or cancellation), then dropped. The owning connection
/// keeps its own `connectionState` and calls ``finishAll(connected:)`` from its
/// state-change hook, or ``finish(_:connected:)`` to release a single token
/// (e.g. on task cancellation).
@MainActor
public final class RemoteTmuxConnectionWaiters {
    private var waiters: [UUID: (Bool) -> Void] = [:]

    public init() {}

    /// Registers `waiter` under `token`. The callback is invoked by a later
    /// ``finishAll(connected:)`` or ``finish(_:connected:)`` call and then dropped.
    public func register(_ token: UUID, _ waiter: @escaping (Bool) -> Void) {
        waiters[token] = waiter
    }

    /// Resumes and drops every registered waiter with `connected`.
    public func finishAll(connected: Bool) {
        guard !waiters.isEmpty else { return }
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending {
            waiter(connected)
        }
    }

    /// Resumes and drops the waiter registered for `token` (if any) with `connected`.
    public func finish(_ token: UUID, connected: Bool) {
        waiters.removeValue(forKey: token)?(connected)
    }
}

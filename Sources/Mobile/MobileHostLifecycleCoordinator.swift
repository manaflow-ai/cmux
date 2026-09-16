import Foundation

/// Coalesces host intent while one generation's resources are being retired.
/// Invalidation is synchronous; cleanup suspends, and only the latest scope starts.
@MainActor
final class MobileHostLifecycleCoordinator<Scope: Equatable & Sendable> {
    private(set) var scope: Scope?
    private(set) var generation = UUID()
    private var transition: Task<Void, Never>?
    var isTransitioning: Bool { transition != nil }
    private let invalidate: @MainActor () -> Void
    private let retire: @MainActor () async -> Void
    private let activate: @MainActor (Scope, UUID) -> Void

    init(
        invalidate: @escaping @MainActor () -> Void,
        retire: @escaping @MainActor () async -> Void,
        activate: @escaping @MainActor (Scope, UUID) -> Void
    ) {
        self.invalidate = invalidate
        self.retire = retire
        self.activate = activate
    }

    /// Repeated desired state is a no-op, including stop while already stopped.
    /// A configuration change can force retirement even when the scope is unchanged.
    func request(_ scope: Scope?, restart: Bool = false) {
        guard restart || self.scope != scope else { return }
        self.scope = scope
        generation = UUID()
        if transition == nil {
            transition = Task { @MainActor [weak self, retire] in
                await retire()
                guard let self else { return }
                // No suspension separates selecting the final intent and starting it.
                // A later request will retire that generation through this same owner.
                self.transition = nil
                if let scope = self.scope { self.activate(scope, self.generation) }
            }
        }
        // Reserve the retiring phase before publishing: a synchronous observer
        // may re-enter with a newer intent, but must never see the old resources as active.
        invalidate()
    }

    /// Explicit shutdown callers can join cleanup; UI policy updates never wait for it.
    func waitForTransition() async {
        await transition?.value
    }
}

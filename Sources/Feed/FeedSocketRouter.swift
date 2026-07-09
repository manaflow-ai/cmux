import CMUXAgentLaunch
import Foundation

/// Routes socket-layer Feed requests (`feed.jump`, `feed.reply`, and the
/// pending-item snapshot read) to their backing collaborators.
///
/// Holds a single injected ``HookSessionResolver`` rather than constructing one
/// per call, so the hook-session disk reader can be pointed at a temporary
/// `~/.cmuxterm` in tests. The snapshot read hops to `@MainActor` to read
/// `FeedCoordinator.shared.store` (the observable Feed state) when invoked
/// off-main from the socket worker.
struct FeedSocketRouter {
    private let resolver: HookSessionResolver

    /// Creates a router.
    ///
    /// - Parameter resolver: Injected so tests can point hook-session resolution
    ///   at a temporary home directory; defaults to a `.default`-backed reader.
    init(resolver: HookSessionResolver = HookSessionResolver()) {
        self.resolver = resolver
    }

    /// Forwards to `HookSessionResolver.resolvesSurface(for:)`: returns `true`
    /// if `workstreamId` maps to a known hook session so the UI can gate the
    /// jump gesture. Actual focus is scheduled via ``focusIfPossible(workstreamId:)``.
    func resolvePossibleSurface(for workstreamId: String) -> Bool {
        resolver.resolvesSurface(for: workstreamId)
    }

    /// Forwards to `HookSessionResolver.focus(workstreamId:)`: fires a
    /// best-effort focus for `workstreamId`, returning `true` when a target was
    /// found and the focus intent was dispatched.
    @MainActor
    func focusIfPossible(workstreamId: String) -> Bool {
        resolver.focus(workstreamId: workstreamId)
    }

    /// Forwards to `HookSessionResolver.sendText(workstreamId:text:)`: types
    /// `text` into the surface bound to `workstreamId`, followed by Return, so
    /// Stop-kind cards can reply without switching focus to the terminal.
    @MainActor
    @discardableResult
    func sendTextToWorkstream(workstreamId: String, text: String) -> Bool {
        resolver.sendText(workstreamId: workstreamId, text: text)
    }

    /// Thread-safe snapshot of the store's items; hops to main to read
    /// the observable state (only if called off-main).
    func snapshot(pendingOnly: Bool) -> [WorkstreamItem] {
        let slot = SnapshotSlot()
        let body: @Sendable () -> Void = { [slot] in
            MainActor.assumeIsolated {
                guard let store = FeedCoordinator.shared.store else { return }
                slot.value = pendingOnly ? store.pending : store.items
            }
        }
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.sync(execute: body)
        }
        return slot.value
    }
}

private final class SnapshotSlot: @unchecked Sendable {
    var value: [WorkstreamItem] = []
}

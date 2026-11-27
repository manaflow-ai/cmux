import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProvider {
    func isCurrentLifecycleGeneration(_ generation: UInt64) -> Bool {
        !isFeatureSuspended && lifecycleGeneration == generation
    }
    /// The generation to capture before detached work that touches panes.
    var currentLifecycleGeneration: UInt64 { lifecycleGeneration }
    func isCurrentRefresh(lifecycle: UInt64, refresh: UInt64) -> Bool {
        !isFeatureSuspended && lifecycleGeneration == lifecycle
            && refreshGeneration == refresh
            && isRegisteredInCatalog()
    }

    /// Suspended work cannot publish through a replacement provider.
    func isRegisteredInCatalog() -> Bool {
        guard !isFeatureSuspended, let current = catalog.provider(for: machine) else { return false }
        return ObjectIdentifier(current) == ObjectIdentifier(self)
    }

    /// A link acknowledgement can suspend between installing and publishing a graph.
    /// Only the current graph may update catalog rows or restored local titles.
    func canPublishCloudState(_ candidate: CloudVMState) -> Bool {
        guard isRegisteredInCatalog(), candidate.machine == machine,
              let current = cloudState else { return false }
        if let cursor = current.cursor {
            return candidate.cursor == cursor
        }
        return candidate == current
    }

    func refresh() async {
        await refreshCurrentGraph(force: false)
    }

    // Matches the protocol's Void return type so existential catalog reads
    // preserve force instead of falling through to its legacy default.
    func refresh(force: Bool) async {
        if force { await refreshDisplays() }
        await refreshCurrentGraph(force: force)
    }

    /// Re-syncs the graph and reports whether the result is authoritative enough
    /// for mutations. Concurrent reads share the provider's refresh owner.
    @discardableResult
    func refreshCurrentGraph(force: Bool) async -> Bool {
        await refreshCoordinator.refresh(force: force) { [weak self] force in
            guard let self else { return false }
            return await self.performRefresh(force: force)
        }
    }

    /// Re-syncs the graph for a caller that cannot wait for the background
    /// recovery read, such as `cmux ssh` opening a workspace. A refresh that
    /// finds the delta-built graph disagreeing with a full snapshot at the same
    /// cursor refuses it once and arms recovery; the next full read adopts the
    /// daemon's answer. Running that read here keeps the open from failing on a
    /// conflict the provider already knows how to resolve (#19214).
    func refreshCurrentGraphResolvingEqualCursorConflict() async -> Bool {
        await Self.refreshResolvingEqualCursorConflict(
            refresh: { [weak self] force in await self?.refreshCurrentGraph(force: force) ?? false },
            conflictArmed: { [weak self] in self?.equalCursorConflict != nil }
        )
    }

    static func refreshResolvingEqualCursorConflict(
        refresh: (Bool) async -> Bool,
        conflictArmed: () -> Bool
    ) async -> Bool {
        if await refresh(false) { return true }
        guard conflictArmed() else { return false }
        return await refresh(true)
    }
}

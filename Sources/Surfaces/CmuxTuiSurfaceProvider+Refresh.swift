import Foundation

extension CmuxTuiSurfaceProvider {
    func refresh() async {
        await refreshCurrentGraph(force: false)
    }

    // Matches the protocol's Void return type so existential catalog reads
    // preserve force instead of falling through to its legacy default.
    func refresh(force: Bool) async {
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
}

import Foundation

extension CmuxTuiSurfaceProvider {
    func refresh() async {
        await refreshCurrentGraph(force: false)
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

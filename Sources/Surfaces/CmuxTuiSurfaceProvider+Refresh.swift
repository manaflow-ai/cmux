import Foundation

extension CmuxTuiSurfaceProvider {
    /// Suspended work cannot publish through a replacement provider.
    func isRegisteredInCatalog() -> Bool {
        guard let current = catalog.provider(for: machine) else { return false }
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

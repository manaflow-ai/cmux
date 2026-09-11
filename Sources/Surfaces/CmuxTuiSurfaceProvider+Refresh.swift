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

    /// Whether this provider is still registered for its machine. Suspended
    /// network work must not write through a replacement provider.
    func isRegisteredInCatalog() -> Bool {
        guard let current = catalog.provider(for: machine) else { return false }
        return ObjectIdentifier(current) == ObjectIdentifier(self)
    }

    /// Link acknowledgements can suspend after installation. Revalidate at publication
    /// so an older callback cannot restore a pre-rename name or a retired provider's graph.
    func canPublishCloudState(_ candidate: CloudVMState) -> Bool {
        guard isRegisteredInCatalog(), candidate.machine == machine,
              let current = cloudState else { return false }
        // Versioned graphs use an O(1) identity check on every event. Only legacy
        // snapshots lack a cursor and need a full comparison to prove ownership.
        if let cursor = current.cursor {
            return candidate.cursor == cursor
        }
        return candidate == current
    }
}

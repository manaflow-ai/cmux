/// Captures the process records needed by ``RemoteOrphanedProcessReaper``.
protocol RemoteOrphanProcessSnapshotCapturing: Sendable {
    func capture() async -> [RemoteOrphanProcessSnapshot]
}

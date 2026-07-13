import CmuxMobilePairedMac

struct StoredMacReconnectStoreRequest: Sendable {
    let store: any MobilePairedMacStoring
    let scope: MobileShellScopeSnapshot
    let generation: Int

    func load() async -> StoredMacReconnectStoreSnapshot {
        if let refresher = store as? any PairedMacBackupRefreshing {
            await refresher.refreshFromBackup(stackUserID: scope.userID)
        }
        do {
            let activeMac = try await store.activeMac(
                stackUserID: scope.userID,
                teamID: scope.teamID
            )
            let allMacs = try await store.loadAll(
                stackUserID: scope.userID,
                teamID: scope.teamID
            )
            return .loaded(request: self, activeMac: activeMac, allMacs: allMacs)
        } catch {
            return .failed(request: self, errorDescription: String(describing: error))
        }
    }
}

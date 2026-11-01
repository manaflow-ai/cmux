import CmuxNextLayout

/// A crashed run's incognito workspaces, from the ledger, on a daemon without state resources: marked
/// discarding, hidden from phones at once (`PhoneIncognitoHiding`, spaces-incognito-audit leak 3), then closed,
/// never shown.
@MainActor enum IncognitoLeftovers {
    static func discard(_ leftover: [String], _ manager: WindowManager) {
        guard !leftover.isEmpty else { return }
        manager.registry.apply { $0.markDiscarding(leftover); return WindowRegistry.Changes() }
        manager.recordIncognitoWorkspaces()
        manager.discard(leftover)
    }
}

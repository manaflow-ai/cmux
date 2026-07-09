import CmuxSettings

/// Transient discovery, optimistic-write, and error state for the Extensions card.
struct BrowserWebExtensionsCardState {
    private(set) var discovered: [SettingsDiscoveredBrowserExtension] = []
    private(set) var isDiscoveryComplete = false
    private(set) var pendingEntries: [BrowserWebExtensionEntry]?
    private(set) var pendingWriteID: UInt64?
    private(set) var hasWriteError = false

    func effectiveEntries(observed: [BrowserWebExtensionEntry]) -> [BrowserWebExtensionEntry] {
        pendingEntries ?? observed
    }

    func canUseImportMenu(supported: Bool, hasObservedValue: Bool) -> Bool {
        supported && hasObservedValue
    }

    mutating func completeDiscovery(_ discovered: [SettingsDiscoveredBrowserExtension]) {
        self.discovered = discovered
        isDiscoveryComplete = true
    }

    mutating func beginWrite(entries: [BrowserWebExtensionEntry], writeID: UInt64) {
        pendingEntries = entries
        pendingWriteID = writeID
        hasWriteError = false
    }

    mutating func reconcileObservedEntries(_ entries: [BrowserWebExtensionEntry]) {
        guard entries == pendingEntries else { return }
        pendingEntries = nil
        pendingWriteID = nil
    }

    mutating func reconcileWriteResult(completedWriteID: UInt64, failed: Bool) {
        guard completedWriteID == pendingWriteID, failed else { return }
        pendingEntries = nil
        pendingWriteID = nil
    }
}

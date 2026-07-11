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
        supported && hasObservedValue && isDiscoveryComplete
    }

    /// The "no extensions added" empty row must wait for the JSON stream's
    /// first value: until then the observed entries are only the default `[]`,
    /// not the persisted state, and configured extensions would flash as
    /// missing.
    func shouldShowEmptyState(entries: [BrowserWebExtensionEntry], hasObservedValue: Bool) -> Bool {
        entries.isEmpty && hasObservedValue
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
        if entries == pendingEntries || pendingWriteID == nil {
            pendingEntries = nil
            pendingWriteID = nil
        }
        hasWriteError = false
    }

    mutating func reconcileWriteResult(
        completedWriteID: UInt64,
        failed: Bool,
        observedEntries: [BrowserWebExtensionEntry]
    ) {
        guard completedWriteID == pendingWriteID else { return }
        pendingWriteID = nil
        if failed {
            pendingEntries = nil
            hasWriteError = true
        } else if observedEntries == pendingEntries {
            pendingEntries = nil
        }
    }
}

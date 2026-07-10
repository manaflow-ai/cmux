import CmuxSettings

/// Transient discovery, optimistic-write, and error state for the Extensions card.
struct BrowserWebExtensionsCardState {
    private(set) var discovered: [SettingsDiscoveredBrowserExtension] = []
    private(set) var isDiscoveryComplete = false
    private(set) var pendingEntries: [BrowserWebExtensionEntry]?
    private(set) var pendingWriteID: UInt64?
    private(set) var hasWriteError = false
    private var pendingStartObservationRevision: UInt64 = 0
    private var matchingObservationRevision: UInt64?
    private var completedWriteSucceeded = false

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

    mutating func beginWrite(
        entries: [BrowserWebExtensionEntry],
        writeID: UInt64,
        observationRevision: UInt64 = 0
    ) {
        pendingEntries = entries
        pendingWriteID = writeID
        pendingStartObservationRevision = observationRevision
        matchingObservationRevision = nil
        completedWriteSucceeded = false
        hasWriteError = false
    }

    mutating func reconcileObservedEntries(
        _ entries: [BrowserWebExtensionEntry],
        observationRevision: UInt64 = .max
    ) {
        guard entries == pendingEntries,
              observationRevision > pendingStartObservationRevision
        else { return }
        matchingObservationRevision = observationRevision
        finishIfWriteSucceeded()
    }

    mutating func reconcileWriteResult(completedWriteID: UInt64, failed: Bool) {
        guard completedWriteID == pendingWriteID else { return }
        completedWriteSucceeded = !failed
        if failed {
            pendingEntries = nil
            pendingWriteID = nil
            matchingObservationRevision = nil
            hasWriteError = true
        } else {
            finishIfWriteSucceeded()
        }
    }

    private mutating func finishIfWriteSucceeded() {
        guard completedWriteSucceeded, matchingObservationRevision != nil else { return }
        pendingEntries = nil
        pendingWriteID = nil
        matchingObservationRevision = nil
        hasWriteError = false
    }
}

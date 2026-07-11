import CmuxSettings

struct BrowserWebExtensionReconciliationPlan: Equatable {
    let desiredEntries: [BrowserWebExtensionEntry]
    let unloadEntries: [BrowserWebExtensionReconciliationUnloadEntry]
    let loadEntries: [BrowserWebExtensionEntry]

    var unloadEntryIDs: [String] {
        unloadEntries.map(\.id)
    }
}

import CmuxSettings

struct BrowserWebExtensionReconciliationPlan: Equatable {
    let desiredEntries: [BrowserWebExtensionEntry]
    let unloadEntries: [BrowserWebExtensionReconciliationUnloadEntry]
    let loadEntries: [BrowserWebExtensionEntry]
    let permissionStateRemovalEntries: [BrowserWebExtensionPermissionStateRemoval]

    var unloadEntryIDs: [String] {
        unloadEntries.map(\.id)
    }
}

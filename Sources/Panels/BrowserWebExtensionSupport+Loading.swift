import CmuxSettings
import CryptoKit
import Foundation
import WebKit

@available(macOS 15.4, *)
extension BrowserWebExtensionSupport {
    private static let actionManifestKeys: Set<String> = [
        "action",
        "browser_action",
        "page_action",
    ]

    var loadedRecordsInOrder: [BrowserWebExtensionLoadedRecord] {
        loadedEntryIDsInOrder.compactMap { loadedByEntryID[$0] }
    }

    func apply(entries: [BrowserWebExtensionEntry]) async {
        settingsLoadGeneration &+= 1
        await apply(entries: entries, generation: settingsLoadGeneration)
    }

    func apply(entries: [BrowserWebExtensionEntry], generation: Int) async {
        guard canApplyWebExtensionLoad(generation: generation) else { return }
        settingsBackedEntryIDs = Set(entries.map(\.id))
        let hiddenEntryIDs = Set(entries.filter { !$0.effectiveShowsToolbarButton }.map(\.id))
        if hiddenEntryIDs != toolbarHiddenEntryIDs {
            toolbarHiddenEntryIDs = hiddenEntryIDs
            refreshAllActionSnapshots()
        }
        let environmentPaths = Self.environmentExtensionPaths()
        let planner = BrowserWebExtensionReconciliationPlanner()
        let plan = planner.plan(
            settingsEntries: entries,
            previousSettingsEntries: configuredSettingsEntries,
            environmentPaths: environmentPaths,
            loadedEntries: loadedByEntryID.values.map {
                BrowserWebExtensionReconciliationPlanner.LoadedEntry(
                    id: $0.entryID,
                    standardizedPath: $0.standardizedPath
                )
            },
            persistedPermissionStateEntries: permissionStateStore.storedStateEntries()
        )
        pruneLoadErrors(
            retainingEntryIDs: settingsBackedEntryIDs.union(plan.desiredEntries.map(\.id))
        )
        configuredSettingsEntries = entries

        var failedUnloadEntries: [BrowserWebExtensionEntry] = []
        for entry in plan.unloadEntries {
            if let failedEntry = unload(
                entryID: entry.id,
                preservePermissionState: entry.preservePermissionState
            ) {
                failedUnloadEntries.append(failedEntry)
            }
        }

        if !failedUnloadEntries.isEmpty {
            guard canApplyWebExtensionLoad(generation: generation) else { return }
            await rollbackSettingsAfterFailedUnloads(
                failedEntries: failedUnloadEntries,
                planner: planner
            )
            rebuildActionSnapshots()
            return
        }

        for entry in plan.permissionStateRemovalEntries {
            removePermissionState(entryID: entry.id, standardizedPath: entry.standardizedPath)
        }

        guard canApplyWebExtensionLoad(generation: generation) else { return }
        for entry in plan.loadEntries where loadedByEntryID[entry.id] == nil {
            await load(entry: entry, generation: generation)
        }

        guard canApplyWebExtensionLoad(generation: generation) else { return }
        rebuildActionSnapshots()
    }

    func canApplyWebExtensionLoad(generation: Int) -> Bool {
        generation == settingsLoadGeneration &&
            !Task.isCancelled &&
            BrowserAvailabilitySettings.isEnabled()
    }

    func context(forActionID actionID: String) -> WKWebExtensionContext? {
        loadedByEntryID[actionID]?.context
    }

    func actionSnapshots(for panelID: UUID) -> [BrowserWebExtensionActionSnapshot] {
        _ = actionSnapshotRevision
        _ = actionSnapshotInvalidationsByPanelID[panelID]?.revision
        let tabAdapter = tabAdapters[panelID]
        return actionSnapshotIDs.compactMap { entryID in
            guard let record = loadedByEntryID[entryID] else { return nil }
            return actionSnapshot(for: record, tabAdapter: tabAdapter)
        }
    }

    func rebuildActionSnapshots() {
        actionSnapshotIDs = loadedRecordsInOrder.map(\.entryID)
        refreshAllActionSnapshots()
    }

    func refreshActionSnapshot(for context: WKWebExtensionContext) {
        guard actionSnapshotIDs.contains(where: { loadedByEntryID[$0]?.context === context }) else {
            rebuildActionSnapshots()
            return
        }
        refreshAllActionSnapshots()
    }

    func refreshActionSnapshot(for action: WKWebExtension.Action, context: WKWebExtensionContext) {
        if let adapter = action.associatedTab as? BrowserWebExtensionTabAdapter,
           let panelID = adapter.panel?.id,
           tabAdapters[panelID] === adapter {
            refreshActionSnapshots(for: panelID)
            return
        }
        refreshActionSnapshot(for: context)
    }

    func refreshAllActionSnapshots() {
        actionSnapshotRevision &+= 1
    }

    func refreshActionSnapshots(for panelID: UUID?) {
        guard let panelID,
              let invalidation = actionSnapshotInvalidationsByPanelID[panelID] else { return }
        invalidation.refresh()
    }

    func extensionPagePanels(usingContextIdentifier contextIdentifier: ObjectIdentifier) -> [BrowserPanel] {
        tabAdapters.values.compactMap(\.panel).filter {
            $0.webExtensionPageContextIdentifier == contextIdentifier
        }
    }

    private func actionSnapshot(
        for record: BrowserWebExtensionLoadedRecord,
        tabAdapter: BrowserWebExtensionTabAdapter?
    ) -> BrowserWebExtensionActionSnapshot? {
        guard record.context.webExtension.manifest.keys.contains(where: Self.actionManifestKeys.contains) else {
            return nil
        }
        guard let action = record.context.action(for: tabAdapter) else { return nil }
        return BrowserWebExtensionActionSnapshot(
            id: record.entryID,
            displayName: action.label,
            icon: action.icon(for: CGSize(width: 32, height: 32))
                ?? record.context.webExtension.icon(for: CGSize(width: 32, height: 32)),
            isEnabled: action.isEnabled,
            badgeText: action.badgeText,
            hasUnreadBadgeText: action.hasUnreadBadgeText,
            showsToolbarButton: !toolbarHiddenEntryIDs.contains(record.entryID),
            canToggleToolbarButton: settingsBackedEntryIDs.contains(record.entryID)
        )
    }

    /// Persists toolbar-button visibility on the matching settings entry. The
    /// settings stream re-applies, so the button set refreshes everywhere
    /// without unloading the extension.
    func setToolbarButtonVisible(_ visible: Bool, entryID: String) {
        Task { @MainActor in
            await persistToolbarButtonVisibility(visible, entryID: entryID)
        }
    }

    func persistToolbarButtonVisibility(_ visible: Bool, entryID: String) async {
        guard let settingsStore, let settingsKey else { return }
        do {
            try await settingsStore.update(settingsKey) { entries in
                guard let index = entries.firstIndex(where: { $0.id == entryID }),
                      entries[index].effectiveShowsToolbarButton != visible else { return }
                entries[index].showsToolbarButton = visible ? nil : false
            }
        } catch {
            recordLoadError(error.localizedDescription, entryID: entryID)
#if DEBUG
            cmuxDebugLog("browser.webext.toolbarVisibility saveFailed id=\(entryID) error=\(error.localizedDescription)")
#endif
        }
    }

    @discardableResult
    private func unload(
        entryID: String,
        preservePermissionState: Bool = true
    ) -> BrowserWebExtensionEntry? {
        guard let record = loadedByEntryID[entryID] else { return nil }
        let extensionPagePanels = extensionPagePanels(
            usingContextIdentifier: ObjectIdentifier(record.context)
        )
        if preservePermissionState {
            persistPermissionState(
                entryID: entryID,
                standardizedPath: record.standardizedPath,
                context: record.context
            )
        }
        do {
            try controller.unload(record.context)
        } catch {
            recordLoadError(error.localizedDescription, entryID: entryID)
#if DEBUG
            cmuxDebugLog("browser.webext.unloadFailed id=\(entryID) error=\(error.localizedDescription)")
#endif
            return record.entry
        }

        removePermissionStateObservers(entryID: entryID, context: record.context)
        if !preservePermissionState {
            removePermissionState(entryID: entryID, standardizedPath: record.standardizedPath)
        }
        loadedByEntryID[entryID] = nil
        loadedEntryIDsInOrder.removeAll { $0 == entryID }
        loadErrorsByEntryID.removeValue(forKey: entryID)
        refreshLoadErrors()

        for panel in extensionPagePanels {
            closeOpenedBrowserTab(panel)
        }

        let closingPopouts = popouts.filter { $0.extensionContext === record.context }
        for popout in closingPopouts {
            popout.closeFromExtensionOrUser()
        }
#if DEBUG
        cmuxDebugLog("browser.webext.unloaded id=\(entryID)")
#endif
        return nil
    }

    @discardableResult
    func unloadAllWebExtensions() -> Bool {
        var didUnloadEveryExtension = true
        for entryID in Array(loadedEntryIDsInOrder) {
            if unload(entryID: entryID) != nil {
                didUnloadEveryExtension = false
            }
        }
        rebuildActionSnapshots()
        return didUnloadEveryExtension
    }

    func loadErrorUpdates() -> AsyncStream<[String: String]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[String: String]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        loadErrorUpdateContinuations[id] = continuation
        continuation.yield(loadErrorsByEntryID)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.loadErrorUpdateContinuations.removeValue(forKey: id)
            }
        }
        return stream
    }

    private func load(entry: BrowserWebExtensionEntry, generation: Int) async {
        do {
            let webExtension = try await makeWebExtension(for: entry)
            guard canApplyWebExtensionLoad(generation: generation) else { return }
            let standardizedPath = BrowserWebExtensionReconciliationPlanner.standardizedResourceRootPath(for: entry)
            guard let context = try load(
                webExtension,
                entryID: entry.id,
                standardizedPath: standardizedPath,
                generation: generation
            ) else {
                return
            }
            guard canApplyWebExtensionLoad(generation: generation) else {
                if !discardStaleLoadedContext(
                    context,
                    entry: entry,
                    standardizedPath: standardizedPath
                ) {
                    await apply(
                        entries: configuredSettingsEntries,
                        generation: settingsLoadGeneration
                    )
                }
                return
            }
            loadedByEntryID[entry.id] = BrowserWebExtensionLoadedRecord(
                entry: entry,
                standardizedPath: standardizedPath,
                context: context
            )
            if !loadedEntryIDsInOrder.contains(entry.id) {
                loadedEntryIDsInOrder.append(entry.id)
            }
            for panel in tabAdapters.values.compactMap(\.panel) {
                panel.retryPendingWebExtensionNavigationIfNeeded()
            }
            loadErrorsByEntryID.removeValue(forKey: entry.id)
            refreshLoadErrors()
#if DEBUG
            cmuxDebugLog(
                "browser.webext.loaded name=\(webExtension.displayName ?? "?") " +
                "version=\(webExtension.displayVersion ?? "?") url=\(entry.path)"
            )
            logRegisteredCommands(for: context)
#endif
        } catch {
            guard canApplyWebExtensionLoad(generation: generation) else { return }
            recordLoadError(error.localizedDescription, entryID: entry.id)
#if DEBUG
            cmuxDebugLog("browser.webext.loadFailed url=\(entry.path) error=\(error.localizedDescription)")
#endif
        }
    }

    private func discardStaleLoadedContext(
        _ context: WKWebExtensionContext,
        entry: BrowserWebExtensionEntry,
        standardizedPath: String
    ) -> Bool {
        do {
            try controller.unload(context)
            removePermissionStateObservers(entryID: entry.id, context: context)
            return true
        } catch {
            loadedByEntryID[entry.id] = BrowserWebExtensionLoadedRecord(
                entry: entry,
                standardizedPath: standardizedPath,
                context: context
            )
            if !loadedEntryIDsInOrder.contains(entry.id) {
                loadedEntryIDsInOrder.append(entry.id)
            }
            recordLoadError(error.localizedDescription, entryID: entry.id)
#if DEBUG
            cmuxDebugLog(
                "browser.webext.staleUnloadFailed id=\(entry.id) error=\(error.localizedDescription)"
            )
#endif
            return false
        }
    }

    private func rollbackSettingsAfterFailedUnloads(
        failedEntries: [BrowserWebExtensionEntry],
        planner: BrowserWebExtensionReconciliationPlanner
    ) async {
        guard let settingsStore, let settingsKey else { return }
        do {
            try await settingsStore.update(settingsKey) { settingsEntries in
                settingsEntries = planner.rollbackEntriesAfterFailedUnloads(
                    settingsEntries: settingsEntries,
                    failedEntries: failedEntries
                )
            }
        } catch {
            for entry in failedEntries {
                recordLoadError(error.localizedDescription, entryID: entry.id)
            }
#if DEBUG
            cmuxDebugLog("browser.webext.rollbackSettingsFailed error=\(error.localizedDescription)")
#endif
        }
    }

    private func makeWebExtension(for entry: BrowserWebExtensionEntry) async throws -> WKWebExtension {
        let url = URL(fileURLWithPath: entry.path)
        if entry.kind == .safariAppExtension, url.pathExtension == "appex" {
            if let bundle = Bundle(url: url) {
                return try await WKWebExtension(appExtensionBundle: bundle)
            }
            let resources = url.appendingPathComponent("Contents/Resources", isDirectory: true)
            return try await WKWebExtension(resourceBaseURL: resources)
        }
        return try await WKWebExtension(resourceBaseURL: url)
    }

    @discardableResult
    private func load(
        _ webExtension: WKWebExtension,
        entryID: String,
        standardizedPath: String,
        generation: Int
    ) throws -> WKWebExtensionContext? {
        let context = WKWebExtensionContext(for: webExtension)
        configureStableContextIdentity(context, entryID: entryID, standardizedPath: standardizedPath)
#if DEBUG
        context.isInspectable = true
#endif
        restorePermissionState(for: context, entryID: entryID, standardizedPath: standardizedPath)
        guard reviewInitialRequiredPermissions(
            for: context,
            entryID: entryID,
            standardizedPath: standardizedPath,
            generation: generation
        ) else {
            return nil
        }
        installPermissionStateObservers(
            for: context,
            entryID: entryID,
            standardizedPath: standardizedPath
        )
        do {
            try controller.load(context)
        } catch {
            removePermissionStateObservers(entryID: entryID, context: context)
            throw error
        }
        return context
    }

    private func configureStableContextIdentity(
        _ context: WKWebExtensionContext,
        entryID: String,
        standardizedPath: String
    ) {
        let identifier = stableContextIdentifier(entryID: entryID, standardizedPath: standardizedPath)
        context.uniqueIdentifier = identifier
        context.baseURL = URL(string: "webkit-extension://\(identifier)/")!
    }

    private func stableContextIdentifier(entryID: String, standardizedPath: String) -> String {
        let identity = "\(entryID)\n\(standardizedPath)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        let hexDigits = Array("0123456789abcdef".utf8)
        let hexBytes = digest.flatMap { byte in
            [hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0f)]]
        }
        return "cmux-\(String(decoding: hexBytes, as: UTF8.self))"
    }

    private func recordLoadError(_ message: String, entryID: String) {
        loadErrorsByEntryID[entryID] = "\(entryID): \(message)"
        refreshLoadErrors()
    }

    private func pruneLoadErrors(retainingEntryIDs: Set<String>) {
        let retainedErrors = loadErrorsByEntryID.filter { retainingEntryIDs.contains($0.key) }
        guard retainedErrors != loadErrorsByEntryID else { return }
        loadErrorsByEntryID = retainedErrors
        refreshLoadErrors()
    }

    private func refreshLoadErrors() {
        loadErrors = loadErrorsByEntryID
            .sorted { $0.key < $1.key }
            .map(\.value)
        for continuation in loadErrorUpdateContinuations.values {
            continuation.yield(loadErrorsByEntryID)
        }
    }
}

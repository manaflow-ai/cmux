import CmuxSettings
import CryptoKit
import Foundation
import WebKit

@available(macOS 15.4, *)
extension BrowserWebExtensionSupport {
    var loadedRecordsInOrder: [BrowserWebExtensionLoadedRecord] {
        loadedEntryIDsInOrder.compactMap { loadedByEntryID[$0] }
    }

    func apply(entries: [BrowserWebExtensionEntry]) async {
        await apply(entries: entries, generation: settingsLoadGeneration)
    }

    func apply(entries: [BrowserWebExtensionEntry], generation: Int) async {
        guard canApplyWebExtensionLoad(generation: generation) else { return }
        let planner = BrowserWebExtensionReconciliationPlanner()
        let plan = planner.plan(
            settingsEntries: entries,
            environmentPaths: Self.environmentExtensionPaths(),
            loadedEntries: loadedByEntryID.values.map {
                BrowserWebExtensionReconciliationPlanner.LoadedEntry(
                    id: $0.entryID,
                    standardizedPath: $0.standardizedPath
                )
            }
        )

        for entry in plan.unloadEntries {
            unload(entryID: entry.id, preservePermissionState: entry.preservePermissionState)
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

    private func actionSnapshot(
        for record: BrowserWebExtensionLoadedRecord,
        tabAdapter: BrowserWebExtensionTabAdapter?
    ) -> BrowserWebExtensionActionSnapshot {
        let action = record.context.action(for: tabAdapter)
        return BrowserWebExtensionActionSnapshot(
            id: record.entryID,
            displayName: action?.label ?? record.context.webExtension.displayName ?? String(
                localized: "browser.webExtension.action.help",
                defaultValue: "Extension"
            ),
            icon: action?.icon(for: CGSize(width: 32, height: 32))
                ?? record.context.webExtension.icon(for: CGSize(width: 32, height: 32)),
            isEnabled: action?.isEnabled ?? true,
            badgeText: action?.badgeText ?? "",
            hasUnreadBadgeText: action?.hasUnreadBadgeText ?? false
        )
    }

    private func unload(entryID: String, preservePermissionState: Bool = true) {
        guard let record = loadedByEntryID[entryID] else { return }
        if preservePermissionState {
            persistPermissionState(entryID: entryID, context: record.context)
        }
        do {
            try controller.unload(record.context)
        } catch {
            recordLoadError(error.localizedDescription, entryID: entryID)
#if DEBUG
            cmuxDebugLog("browser.webext.unloadFailed id=\(entryID) error=\(error.localizedDescription)")
#endif
            return
        }

        removePermissionStateObservers(entryID: entryID)
        if !preservePermissionState {
            removePermissionState(entryID: entryID)
        }
        loadedByEntryID[entryID] = nil
        loadedEntryIDsInOrder.removeAll { $0 == entryID }
        loadErrorsByEntryID.removeValue(forKey: entryID)
        refreshLoadErrors()

        let closingPopouts = popouts.filter { $0.extensionContext === record.context }
        for popout in closingPopouts {
            popout.closeFromExtensionOrUser()
        }
#if DEBUG
        cmuxDebugLog("browser.webext.unloaded id=\(entryID)")
#endif
    }

    func unloadAllWebExtensions() {
        for entryID in Array(loadedEntryIDsInOrder) {
            unload(entryID: entryID)
        }
        loadErrorsByEntryID.removeAll()
        refreshLoadErrors()
        rebuildActionSnapshots()
    }

    private func load(entry: BrowserWebExtensionEntry, generation: Int) async {
        do {
            let webExtension = try await makeWebExtension(for: entry)
            guard canApplyWebExtensionLoad(generation: generation) else { return }
            let standardizedPath = BrowserWebExtensionReconciliationPlanner.standardizedResourceRootPath(for: entry)
            let context = try load(webExtension, entryID: entry.id, standardizedPath: standardizedPath)
            loadedByEntryID[entry.id] = BrowserWebExtensionLoadedRecord(
                entryID: entry.id,
                standardizedPath: standardizedPath,
                context: context
            )
            if !loadedEntryIDsInOrder.contains(entry.id) {
                loadedEntryIDsInOrder.append(entry.id)
            }
            loadErrorsByEntryID.removeValue(forKey: entry.id)
            refreshLoadErrors()
#if DEBUG
            cmuxDebugLog(
                "browser.webext.loaded name=\(webExtension.displayName ?? "?") " +
                "version=\(webExtension.displayVersion ?? "?") url=\(entry.path)"
            )
#endif
        } catch {
            guard canApplyWebExtensionLoad(generation: generation) else { return }
            recordLoadError(error.localizedDescription, entryID: entry.id)
#if DEBUG
            cmuxDebugLog("browser.webext.loadFailed url=\(entry.path) error=\(error.localizedDescription)")
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
        standardizedPath: String
    ) throws -> WKWebExtensionContext {
        let context = WKWebExtensionContext(for: webExtension)
        configureStableContextIdentity(context, entryID: entryID, standardizedPath: standardizedPath)
#if DEBUG
        context.isInspectable = true
#endif
        restorePermissionState(for: context, entryID: entryID)
        installPermissionStateObservers(for: context, entryID: entryID)
        do {
            try controller.load(context)
        } catch {
            removePermissionStateObservers(entryID: entryID)
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

    private func refreshLoadErrors() {
        loadErrors = loadErrorsByEntryID
            .sorted { $0.key < $1.key }
            .map(\.value)
    }
}

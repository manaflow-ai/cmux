import CmuxSettings
import WebKit

@available(macOS 15.4, *)
extension BrowserWebExtensionSupport {
    var loadedRecordsInOrder: [BrowserWebExtensionLoadedRecord] {
        loadedEntryIDsInOrder.compactMap { loadedByEntryID[$0] }
    }

    func apply(entries: [BrowserWebExtensionEntry]) async {
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

        for entryID in plan.unloadEntryIDs {
            unload(entryID: entryID)
        }

        for entry in plan.loadEntries where loadedByEntryID[entry.id] == nil {
            await load(entry: entry)
        }

        rebuildActionSnapshots()
    }

    func context(forActionID actionID: String) -> WKWebExtensionContext? {
        loadedByEntryID[actionID]?.context
    }

    func rebuildActionSnapshots() {
        actionSnapshots = loadedRecordsInOrder.map { actionSnapshot(for: $0) }
    }

    func refreshActionSnapshot(for context: WKWebExtensionContext) {
        guard let record = loadedRecordsInOrder.first(where: { $0.context === context }) else { return }
        var snapshots = actionSnapshots
        guard let index = snapshots.firstIndex(where: { $0.id == record.entryID }) else {
            rebuildActionSnapshots()
            return
        }
        snapshots[index] = actionSnapshot(for: record)
        actionSnapshots = snapshots
    }

    private func actionSnapshot(for record: BrowserWebExtensionLoadedRecord) -> BrowserWebExtensionActionSnapshot {
        let action = record.context.action(for: activeTabAdapter)
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

    private func unload(entryID: String) {
        guard let record = loadedByEntryID[entryID] else { return }
        do {
            try controller.unload(record.context)
        } catch {
            recordLoadError(error.localizedDescription, entryID: entryID)
#if DEBUG
            cmuxDebugLog("browser.webext.unloadFailed id=\(entryID) error=\(error.localizedDescription)")
#endif
            return
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

    private func load(entry: BrowserWebExtensionEntry) async {
        do {
            let webExtension = try await makeWebExtension(for: entry)
            let context = try load(webExtension)
            let standardizedPath = BrowserWebExtensionReconciliationPlanner.standardizedPath(entry.path)
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
    private func load(_ webExtension: WKWebExtension) throws -> WKWebExtensionContext {
        let context = WKWebExtensionContext(for: webExtension)
#if DEBUG
        context.isInspectable = true
#endif
        try controller.load(context)
        return context
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

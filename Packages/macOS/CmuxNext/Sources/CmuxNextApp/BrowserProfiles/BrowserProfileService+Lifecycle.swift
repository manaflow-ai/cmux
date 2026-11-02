import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDaemon
import Foundation

/// Deleting a browser profile with its data, removing that data once no
/// engine holds it, and moving imports made before profiles existed into
/// their own profiles (data-model.md 5).
extension BrowserProfileService {
    /// Deletes profile `id`: its tabs move to `default` (a live page never
    /// keeps a deleted cookie jar), every workspace and room
    /// default naming it is cleared, and its engine data is removed now when
    /// no engine opened it in this process, else at the next launch.
    func delete(_ id: String) throws {
        guard id != BrowserProfileRecord.defaultID else { throw BrowserProfileBookError.defaultProfile }
        guard isKnown(id) else { throw BrowserProfileBookError.unknownProfile }
        for (tab, pane) in browserTabs(in: id) {
            move(tab, in: pane, to: BrowserProfileRecord.defaultID, notice: nil)
        }
        if usesDaemonRecords {
            // The daemon clears the workspace and room defaults naming it.
            services.machines.local.send("delete-browser-profile") { try await $0.deleteBrowserProfile(id) }
        } else if usesPersonalState {
            for workspace in workspacesUsing(id) {
                let request = SetPersonalWorkspaceRequest(sessionID: workspace.session, workspaceKey: WorkspaceKey(rawValue: workspace.key),
                                                          browserProfileID: .clear)
                services.machines.local.send("set-personal-workspace") { try await $0.setPersonalWorkspace(request) }
            }
            for room in services.machines.local.store.profiles where room.browserProfileID?.rawValue == id {
                let roomID = room.id
                services.machines.local.send("update-profile") { try await $0.updateProfile(roomID, browserProfileID: .clear) }
            }
        }
        try edit { $0.markDeleted(id) }
        services.cache.dropHistory(for: BrowserProfileRecord.engineProfile(for: id))
        services.bookmarks.dropProfile(id)
        Task { [sync = services.onboarding.historySync] in _ = try? await sync.removeImported(profile: id, bookmarks: nil, forgetPages: false) }  // task-owner: its imports and their sync go too
        cleanUpDeletedProfiles()
    }

    /// Every browser tab (on every machine) whose record names `id`.
    func browserTabs(in id: String) -> [(TabModel, PaneModel)] {
        var found: [(TabModel, PaneModel)] = []
        for (workspace, _) in services.machines.allWorkspaces {
            for pane in workspace.screens.flatMap(\.panes) {
                for tab in pane.tabs where tab.isFrontendOwned && tab.browserProfileID == id { found.append((tab, pane)) }
            }
        }
        return found
    }

    /// Removes the engine data of deleted profiles that no engine opened in
    /// this process (Chromium and WebKit keep an opened store's files until
    /// the process ends); the rest waits for the next launch.
    func cleanUpDeletedProfiles() {
        // A service that never loaded its file (tests) touches no data.
        let pending = book.pendingCleanup
        guard file != nil, !pending.isEmpty else { return }
        let cef = services.cache.cef, webKit = services.cache.webKit.profileStore
        let ready = cleanupClaims.claim(pending) { cef.hasOpened($0) || webKit.loadedProfiles.contains($0) }
        guard !ready.isEmpty else { return }
        let cleanup = BrowserProfileStorageCleanup(chromiumRoot: cef.storageRoot)
        let bundleID = services.environment.launch.bundleID
        // task-owner: one-shot removal of deleted profiles' files; reports back once
        Task { [weak self] in
            let removed = await Task.detached { cleanup.removeChromiumData(for: ready) }.value
            var done: [String] = []
            for id in removed {
                guard let profile = BrowserProfileRecord.engineProfile(for: id) else { continue }
                await webKit.clearData(for: profile)
                try? FileManager.default.removeItem(at: SiteSettingsRegistry.defaultFile(for: profile, bundleIdentifier: bundleID))
                done.append(id)
            }
            self?.cleanupClaims.release(ready)
            try? self?.edit { $0.finishCleanup(done) }
        }
    }

    /// Imports made before browser profiles existed sit in `default`: each
    /// source becomes its own profile (its proposed id) and its saved data
    /// moves there. Runs once.
    func migrateImports() {
        guard let store = importStore else { return }
        guard !book.importsMigrated else { return seedImportedHistory() }
        // task-owner: one-shot migration of the import store at launch
        Task { [weak self] in
            let pending = await store.sourcesInDefaultProfile()
            let finished = await BrowserProfileBook.migrateImports(pending, id: \.proposedProfileID, migrate: { record in
                guard let self else { return }
                _ = try await self.createProfile(id: record.proposedProfileID, name: record.displayName, color: nil, icon: nil,
                                            source: record.sourceFields)
                try await store.retarget(record.sourceKey, to: record.proposedProfileID)
            }, failed: { record, reason in
                self?.logger.error("migrate import \(record.sourceKey, privacy: .public): \(reason, privacy: .public)")
            })
            if finished { try? self?.edit { $0.importsMigrated = true } }
            self?.seedImportedHistory()
        }
    }

    /// Each profile's imported history goes into its omnibar; Keep in Sync starts watching.
    private func seedImportedHistory() {
        guard importStore != nil else { return }
        let sync = services.onboarding.historySync, profiles = ordered.map(\.id)
        // task-owner: one-shot launch load of the import store; the sync owns its watches
        Task { await sync.start(profiles: profiles) }
    }
}

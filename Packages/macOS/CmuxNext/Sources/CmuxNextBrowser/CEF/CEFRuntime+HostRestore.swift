import Foundation

/// Every page of a crashed Chromium Host back on the next host (task 083 of
/// plans/cmux-next/chrome-parity/p01-process.md, feature `chromiumHostRestoreTabs`).
///
/// Chrome restarts a crashed GPU process within its crash budget and its clients make their surfaces again
/// (content/browser/gpu/gpu_process_host.cc); a session restore gives each tab its saved navigation entries and
/// loads a background tab only when it is activated (chrome/browser/sessions/session_restore.cc, `TabLoader`).
/// Here the Chromium Host is both: when the supervisor's budget had room for the end, a new host starts at once,
/// each tab's saved navigation is read from its daemon record meanwhile, and each tab restores it with
/// `cmux_tab_restore_navigation` (``CEFTab/attach(browser:)``) when it gets its browser: a shown tab now, a hidden
/// or discarded one when it shows. Entries with POST data are never sent again (the record refuses them).
extension CEFRuntime {
    /// The host ended within its restart budget: `tabs`, every page it showed in every window and profile, come back on
    /// a new host started now, with the saved navigation `read` gives each one (nil: each loads its address).
    func restorePagesOnNextHost(_ tabs: [CEFTab], reading read: ChromiumHostSavedNavigation?) {
        guard let restores = hostStart?.pageRestores else { return }
        let generation = restores.begin()
        let waiting = tabs.filter { $0.beginHostRestore(in: restores, generation: generation) }
        guard !waiting.isEmpty else { return }
        Self.restartHost(self, restoring: waiting, generation: generation, read: read)
    }

    /// The start waits off the main actor, as a sad tab's Reload does (``reloadAfterHostRestart(_:)``): the reads, the
    /// start and the restore each run on main as the runtime's own calls, and the reads overlap the host's start.
    private nonisolated static func restartHost(_ runtime: CEFRuntime, restoring tabs: [CEFTab], generation: UInt64,
                                                read: ChromiumHostSavedNavigation?) {
        // task-owner: one per restored host end; the shared attach (CEFHostStart) owns the start, quit fails it, and a
        // later end's restore supersedes this one (its generation)
        Task { [weak runtime] in
            guard let runtime else { return }
            async let saved = runtime.savedNavigations(of: tabs, read: read)
            let attached: Bool
            do {
                try await runtime.start(layout: nil, trigger: "hostRestart")
                attached = true
            } catch {
                attached = false
            }
            await runtime.restoreOnNextHost(tabs, saved: await saved, attached: attached, generation: generation)
        }
    }

    /// Each tab's saved navigation by tab, read at once for all of them.
    private func savedNavigations(of tabs: [CEFTab], read: ChromiumHostSavedNavigation?) async -> [ObjectIdentifier: String] {
        guard let read else { return [:] }
        let asks = tabs.compactMap { tab in tab.hostRestoreURL.map { (ObjectIdentifier(tab), tab.id, $0) } }
        return await withTaskGroup(of: (ObjectIdentifier, String?).self) { group in
            for (key, id, url) in asks {
                group.addTask {
                    guard case .chromium(let state)? = await read(id, url), !state.isEmpty else { return (key, nil) }
                    return (key, state)
                }
            }
            var saved: [ObjectIdentifier: String] = [:]
            for await (key, state) in group { saved[key] = state }
            return saved
        }
    }

    /// The new host is attached (or could not start): each tab still waiting for this restore comes back on it.
    private func restoreOnNextHost(_ tabs: [CEFTab], saved: [ObjectIdentifier: String], attached: Bool, generation: UInt64) {
        guard let restores = hostStart?.pageRestores else { return }
        let started = attached && !awaitsHostRestart
        let restoresNavigation = started && navigationRestoreSupported
        for tab in tabs where restores.phase(of: tab) == .reading(generation) {
            if started {
                tab.restoreOnRestartedHost(restoresNavigation ? saved[ObjectIdentifier(tab)] : nil, in: restores)
            } else {
                tab.hostRestoreFailed(in: restores)
            }
        }
    }

    /// The attached Chromium restores a saved navigation (fork API 10, ``CEFTab/navigationRestoreForkAPI``).
    private var navigationRestoreSupported: Bool {
        guard let shim else { return false }
        return shim.navigationRestoreSupported() == 1 && shim.forkAPIVersion() >= CEFTab.navigationRestoreForkAPI
    }
}

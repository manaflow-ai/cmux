public import Foundation

extension CEFEngine {
    /// Clear Browsing Data (cx-d0d.23) in `profile`'s Chromium store:
    /// cookies created since `since` (nil: all time) and the HTTP cache,
    /// which Chromium clears whole for any range. One of `liveTabs` (the
    /// profile's open tabs) clears the HTTP cache of a profile in use; a
    /// profile Chromium has not opened in this process has its cache
    /// directories deleted, the service workers' Cache Storage with them.
    /// A profile in use keeps its Cache Storage: Chromium owns the open
    /// directory. A profile Chromium never stored has nothing to clear.
    /// Starts Chromium for cookies; throws when it cannot start.
    public func clearBrowsingData(_ profile: BrowserProfileID, cookies: Bool, cache: Bool, since: Date?,
                                  liveTabs: [CEFTab]) async throws {
        let directory = CEFRuntime.shared.storage.cachePath(for: profile)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        if cache {
            // The profile's own store: a remote-localhost tab has a derived one (`machineStore`).
            if let tab = liveTabs.first(where: { $0.profileID == profile && $0.machineStore == nil }) {
                // A tab that cannot answer (not started, closing) leaves the cache; cookies still clear.
                _ = try? await tab.devTools(method: "Network.clearBrowserCache", params: [:])
            } else if !hasOpened(profile) {
                Self.removeCaches(in: directory, since: since)
            }
        }
        guard cookies else { return }
        try await CEFRuntime.shared.start(layout: layout, trigger: "clearBrowsingData")
        try await clearCookies(profile, since: since)
    }

    /// Chromium's caches in a profile directory. `Service Worker/CacheStorage` holds the files the
    /// sites' service workers fetched (the Cache API; WebKit's fetch cache is the same kind, and
    /// `WebKitProfileStore.cacheTypes` clears it). The worker registrations beside it
    /// (`Service Worker/Database`) are site data: they stay.
    static let cacheDirectories = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
                                   "Service Worker/CacheStorage"]

    /// Moves the caches aside here (before Chromium can open the profile)
    /// and deletes them off the main thread: they can hold many files.
    /// Returns that delete, for a test to wait for; nil when nothing moved.
    @discardableResult
    static func removeCaches(in directory: URL, since: Date?) -> Task<Void, Never>? {
        let manager = FileManager.default
        var aside: [URL] = []
        for name in cacheDirectories {
            let from = directory.appending(path: name)
            let to = directory.appending(path: ".cleared-\(UUID().uuidString)")
            if (try? manager.moveItem(at: from, to: to)) != nil { aside.append(to) }
        }
        guard !aside.isEmpty else { return nil }
        // task-owner: one-shot delete of moved-aside cache directories
        return Task.detached(priority: .utility) {
            for url in aside { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Microseconds between 1601-01-01 (Chromium's epoch) and 1970-01-01.
    static let chromiumEpochOffset: Int64 = 11_644_473_600_000_000

    /// Deletes `profile`'s cookies created at or after `since` (nil: every
    /// cookie) through the shim's `cmux_shim_clear_cookies`, also for a
    /// profile no tab has opened yet.
    private func clearCookies(_ profile: BrowserProfileID, since: Date?) async throws {
        let runtime = CEFRuntime.shared
        guard let shim = runtime.shim, runtime.state == .ready else { throw BrowserTabError.closed }
        let start = since.map { Int64($0.timeIntervalSince1970 * 1_000_000) + Self.chromiumEpochOffset } ?? 0
        _ = try await runtime.profileWrite(profile, label: "cookie clear", timeout: CEFRuntime.cookieImportTimeout) { path, id in
            shim.clearCookies(path, id, start)
        }
    }
}

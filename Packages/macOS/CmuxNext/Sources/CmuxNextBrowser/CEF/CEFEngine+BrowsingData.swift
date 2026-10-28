import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

extension CEFEngine {
    /// Clear Browsing Data (cx-d0d.23) in `profile`'s Chromium store:
    /// cookies created since `since` (nil: all time) and the HTTP cache,
    /// which Chromium clears whole for any range. One of `liveTabs` (the
    /// profile's open tabs) clears the cache of a profile in use; a profile
    /// Chromium has not opened in this process has its cache directories
    /// deleted. A profile Chromium never stored has nothing to clear.
    /// Starts Chromium for cookies; throws when it cannot start. The profile directory's checks and moves
    /// run on `work`'s files lane, the delete of the moved-aside caches on its bulk lane.
    public func clearBrowsingData(_ profile: BrowserProfileID, cookies: Bool, cache: Bool, since: Date?,
                                  liveTabs: [CEFTab], work: BackgroundWork) async throws {
        let directory = CEFRuntime.shared.storage.cachePath(for: profile)
        let stored = try await work.run(.userBlocking, mayBlock: .files) { FileManager.checked.fileExists(atPath: directory.path) }
        guard stored else { return }
        if cache {
            // The profile's own store: a remote-localhost tab has a derived one (`machineStore`).
            if let tab = liveTabs.first(where: { $0.profileID == profile && $0.machineStore == nil }) {
                // A tab that cannot answer (not started, closing) leaves the cache; cookies still clear.
                _ = try? await tab.devTools(method: "Network.clearBrowserCache", params: [:])
            } else if !hasOpened(profile) {
                // Moved aside before Chromium can open the profile (the cookie clear below starts it).
                let aside = try await work.run(.userBlocking, mayBlock: .files) { Self.moveCachesAside(in: directory) }
                // They can hold many files: the bulk lane, nobody waits.
                if !aside.isEmpty {
                    work.post(.bestEffort, mayBlock: .bulkFiles) {
                        for url in aside { try? FileManager.checked.removeItem(at: url) }
                    }
                }
            }
        }
        guard cookies else { return }
        try await startRuntime(trigger: "clearBrowsingData")
        try await clearCookies(profile, since: since)
    }

    /// Chromium's caches in a profile directory.
    nonisolated static let cacheDirectories = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"]

    /// Moves the caches aside (one rename each) and returns where they went; on a files lane.
    private nonisolated static func moveCachesAside(in directory: URL) -> [URL] {
        var aside: [URL] = []
        for name in cacheDirectories {
            let from = directory.appending(path: name)
            let to = directory.appending(path: ".cleared-\(UUID().uuidString)")
            if (try? FileManager.checked.moveItem(at: from, to: to)) != nil { aside.append(to) }
        }
        return aside
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

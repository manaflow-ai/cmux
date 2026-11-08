import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// The home daemon side: the read-only status the stars and bars read in the same frame, the
/// omnibar's bookmark index, and the one-time copy of an older build's file.
extension BookmarkService {
    /// Follows the home daemon's capability: when it appears, copy an older build's file over,
    /// read the status of the pages on screen and run the legacy import pass. When it goes, the
    /// stars and bars keep what they show and edits are refused until it is back.
    func observeHome() {
        // task-owner: lives as long as the service; event-driven (Observation)
        homeObservation = Task { [weak self] in
            // A trigger: a daemon restart that still serves bookmarks reads everything again.
            for await serves in ObservationStream({ [weak self] in ObservationTrigger(self?.usesDaemon ?? false) }) {
                guard let self, serves.value else { continue }
                await migrateFileToDaemon()
                for profile in shownProfiles() { daemonChanged(profile) }
                // Earlier browser imports become bookmarks once, after the daemon takes the writes.
                await migrateLegacyImports()
            }
        }
    }

    /// The profiles of the live chromes and suggestion engines, and the default one.
    func shownProfiles() -> Set<String> {
        var profiles: Set<String> = [BrowserProfileRecord.defaultID]
        for chrome in chromes.values { if let entry = chrome.entry { profiles.insert(profile(of: entry.tab.profileID)) } }
        return profiles.union(feeds.keys)
    }

    // MARK: Status

    /// The ids of the links to the page `url`, nil while its status is unknown.
    func bookmarkIDs(for url: URL, profile: String) -> [String]? {
        statuses.ids(for: url, profile: profile)
    }

    /// The pages `profile`'s live tabs show that can be bookmarked (one per page).
    func shownURLs(_ profile: String) -> [String] {
        var urls: [String] = []
        var seen: Set<String> = []
        for chrome in chromes.values {
            guard let entry = chrome.entry, self.profile(of: entry.tab.profileID) == profile,
                  let url = entry.tab.state.url, Self.canBookmark(url), seen.insert(url.absoluteString).inserted else { continue }
            urls.append(url.absoluteString)
        }
        return urls
    }

    /// Reads `profile`'s status for the pages on screen: one read in flight per profile; a call
    /// while one runs reads once more after it, so the last change always lands.
    func refreshStatus(_ profile: String) {
        guard usesDaemon else { return }
        guard statusReads[profile] == nil else { statusStale.insert(profile); return }
        let urls = shownURLs(profile)
        let routed = routed
        // task-owner: one bookmarks.status read; ends with its reply (a follow-up read is its own task)
        statusReads[profile] = Task { [weak self] in
            let status = try? await routed.status(profile: profile, urls: urls)
            guard let self, !Task.isCancelled else { return }
            statusReads[profile] = nil
            if let status { applyStatus(status, profile: profile) }
            if statusStale.remove(profile) != nil { refreshStatus(profile) }
        }
    }

    /// A status the daemon answered (``BookmarkStatusCache/apply(_:profile:shown:)``).
    func applyStatus(_ status: BookmarkRoutedClient.Status, profile: String) {
        if statuses.apply(status, profile: profile, shown: Set(shownURLs(profile))) { refreshChromes(profiles: [profile]) }
    }

    /// The star's own edit shows in the same frame; the daemon's change event then confirms it.
    func noteBookmarks(_ ids: [String], url: URL, profile: String, barFilled: Bool? = nil) {
        statuses.note(ids, url: url, profile: profile, barFilled: barFilled)
        refreshChromes(profiles: [profile])
    }

    // MARK: Omnibar index

    /// Bookmark rows in a browser profile's omnibar (star icon): the profile's links go to its
    /// suggestion engine, read again on every change (plans/cmux-next/omnibar-suggestions.md).
    func feed(_ engine: OmniboxSuggestionEngine, profile: String) {
        feeds[profile, default: []].append { [weak engine] in engine }
        refreshFeeds(profile)
    }

    /// Reads `profile`'s links for its engines; an engine that is gone leaves the list.
    func refreshFeeds(_ profile: String) {
        feeds[profile]?.removeAll { $0() == nil }
        guard let engines = feeds[profile], !engines.isEmpty, usesDaemon else {
            if feeds[profile]?.isEmpty == true { feeds[profile] = nil }
            return
        }
        let routed = routed
        // task-owner: one bookmarks.list read; ends with its reply
        Task { [weak self] in
            guard let nodes = try? await routed.list(profile: profile) else { return }
            let rows = Self.rows(nodes)
            for engine in self?.feeds[profile] ?? [] { engine()?.setBookmarks(rows) }
        }
    }

    /// Pure: bookmark nodes as index rows (last use, else creation, is the visit time).
    nonisolated static func rows(_ nodes: [BookmarkNode]) -> [OmniboxHistoryRow] {
        nodes.compactMap { node in
            guard let url = node.url else { return nil }
            return OmniboxHistoryRow(url: url, title: node.title.isEmpty ? nil : node.title, visitCount: 1, typedCount: 1,
                                     lastVisit: node.lastUsed ?? node.created)
        }
    }

    // MARK: An older build's file

    /// Copies this Mac's `bookmarks.json` (an older build's store) into the daemon, which keeps its
    /// ids and resumes a copy that stopped; deletes the file after.
    func migrateFileToDaemon() async {
        guard !migrating, let directory else { return }
        let file = directory.appending(path: "bookmarks.json")
        guard let document = await Self.read(file) else { return }
        migrating = true
        defer { migrating = false }
        do {
            try await routed.importLegacyFile(document)
            await Self.remove(file)
            logger.info("bookmarks moved into the home daemon")
        } catch {
            logger.error("copy bookmarks to the daemon: \(String(describing: error), privacy: .public)")
        }
    }

    /// The file's text, off the main actor; nil when there is none.
    @concurrent nonisolated private static func read(_ file: URL) async -> String? {
        guard let data = try? Data(blockingContentsOf: file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @concurrent nonisolated private static func remove(_ file: URL) async {
        try? FileManager.checked.removeItem(at: file)
    }
}

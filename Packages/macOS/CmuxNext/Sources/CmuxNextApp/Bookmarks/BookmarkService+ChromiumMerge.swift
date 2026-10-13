import CmuxNextDaemon
import Foundation

/// The chrome.bookmarks bridge merges, never replaces (plans/cmux-next/bookmarks.md
/// section 4, cx-d0d.92): before the first sync of a Chromium store, the home
/// daemon merges that store's own `Bookmarks` file into the profile's tree
/// (`merge-bookmarks`, once per store). The daemon owns the merge and its
/// record; this side only reads the file and waits for the reply.
extension BookmarkService {
    /// Merges `store`'s Chromium bookmarks into `profile`'s tree and reloads
    /// the tree. False when the store must not sync: the daemon cannot merge
    /// (no `bookmarks-merge-v1`), the file cannot be read, or the merge failed.
    func mergeChromiumStore(_ store: String, profile: String) async -> Bool {
        guard usesDaemon, let connection = services.machines.local.connection, connection.supportsBookmarkMerge else {
            logger.error("chrome.bookmarks: no merge-bookmarks on the home daemon; \(profile, privacy: .public) is not synced")
            return false
        }
        let directory = URL(filePath: store)
        let file = directory.appending(path: "Bookmarks")
        // A store without the file has an empty model: the merge records the key.
        let text: String?
        do {
            text = try await Task.detached(priority: .utility) { () throws -> String? in
                guard FileManager.default.fileExists(atPath: file.path) else { return nil }
                return try String(contentsOf: file, encoding: .utf8)
            }.value
        } catch {
            logger.error("chrome.bookmarks: cannot read a store's Bookmarks file: \(String(describing: error), privacy: .public)")
            return false
        }
        let request = MergeBookmarksRequest(browserProfileID: profile, mergeKey: "chromium-store:" + directory.lastPathComponent,
                                            chromiumBookmarks: text ?? #"{"roots":{}}"#, mutation: nil)
        do {
            let result = try await connection.mergeBookmarks(request)
            if result.created > 0 {
                // The sync must carry the merged nodes, or it removes them from Chromium.
                daemonChanged(profile)
                await fetching[profile]?.value
            }
            return true
        } catch {
            logger.error("chrome.bookmarks: merge-bookmarks \(profile, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

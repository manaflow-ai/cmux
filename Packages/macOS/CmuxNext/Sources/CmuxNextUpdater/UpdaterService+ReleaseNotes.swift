public import Foundation

extension UpdaterService {
    /// This build's signed release notes (next to its feed, or the test feed),
    /// cached under Caches; nil without an https feed (DEV builds without one).
    public var releaseNotes: ReleaseNotesStore? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cache = caches.appending(path: "\(identity.bundleIdentifier ?? "cmux")/release-notes", directoryHint: .isDirectory)
        return ReleaseNotesStore(feedURL: testFeedURL ?? identity.feed().url, cache: cache)
    }
}

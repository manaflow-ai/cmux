public import Foundation

extension UpdaterService {
    /// This build's signed release notes (next to its feed, or the test feed),
    /// cached under Caches; nil without an https feed (DEV builds without one).
    public var releaseNotes: ReleaseNotesStore? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cache = caches.appending(path: "\(identity.bundleIdentifier ?? "cmux")/release-notes", directoryHint: .isDirectory)
        return ReleaseNotesStore(feedURL: testFeedURL ?? identity.feed().url, cache: cache)
    }

    /// The What's New sources of a build: the bundled documents, and the
    /// signed notes next to its feed (nightly digests), when it has one. A
    /// DEV build also reads `CMUX_NEXT_WHATS_NEW_DIR` (a folder laid out like
    /// the bundle: index.json plus <version>.json) for previews and proofs.
    nonisolated static func whatsNewSources(identity: UpdateBuildIdentity,
                                            environment: [String: String] = ProcessInfo.processInfo.environment) -> [any WhatsNewSource] {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cache = caches.appending(path: "\(identity.bundleIdentifier ?? "cmux")/release-notes", directoryHint: .isDirectory)
        let feed = ReleaseNotesStore(feedURL: identity.feed().url, cache: cache).map { FeedWhatsNewSource(store: $0) }
        var sources: [any WhatsNewSource] = [BundledWhatsNewSource.app] + (feed.map { [$0] } ?? [])
        if identity.track == .development, let folder = environment["CMUX_NEXT_WHATS_NEW_DIR"], !folder.isEmpty {
            sources.append(BundledWhatsNewSource(directory: URL(fileURLWithPath: folder, isDirectory: true)))
        }
        return sources
    }
}

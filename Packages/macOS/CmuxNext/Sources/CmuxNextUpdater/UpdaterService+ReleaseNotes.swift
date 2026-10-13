public import Foundation

extension UpdaterService {
    /// This build's signed release notes (next to its feed, or the test feed),
    /// cached under Caches; nil without an https feed (DEV builds without one).
    public var releaseNotes: ReleaseNotesStore? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cache = caches.appending(path: "\(identity.bundleIdentifier ?? "cmux")/release-notes", directoryHint: .isDirectory)
        #if DEBUG
        // The update harness signs its own notes next to its loopback feed.
        if let harness = UpdateHarness.current, let key = harness.contentKey {
            return ReleaseNotesStore(feedURL: harness.feedURL, cache: cache.appending(path: "harness", directoryHint: .isDirectory), publicKey: key)
        }
        #endif
        return ReleaseNotesStore(feedURL: testFeedURL ?? identity.feed().url, cache: cache)
    }

    /// The changelog page's media (cx-urd.61.1): signed highlight media, the bundled What's New
    /// media (and a DEV build's `CMUX_NEXT_WHATS_NEW_DIR`), cached beside the notes.
    public var releaseMedia: ReleaseMediaStore? {
        guard let releaseNotes else { return nil }
        var directories = [BundledWhatsNewSource.app.directory].compactMap { $0 }
        if identity.track == .development, let folder = ProcessInfo.processInfo.environment["CMUX_NEXT_WHATS_NEW_DIR"], !folder.isEmpty {
            directories.append(URL(fileURLWithPath: folder, isDirectory: true))
        }
        return releaseNotes.media(bundledDirectories: directories)
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

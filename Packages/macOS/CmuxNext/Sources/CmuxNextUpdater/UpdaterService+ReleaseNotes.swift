import CmuxUpdater
public import Foundation

extension UpdaterService {
    /// This build's signed release notes (next to its feed, or the test feed),
    /// cached under Caches; nil without an https feed (DEV builds without one).
    public var releaseNotes: ReleaseNotesStore? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cache = caches.appending(path: "\(identity.bundleIdentifier ?? "cmux")/release-notes", directoryHint: .isDirectory)
        #if DEBUG || CMUX_BENCH_HOOKS
        // The update harness signs its own notes next to its loopback feed.
        if let harness = UpdateHarness.current, let key = harness.contentKey {
            return ReleaseNotesStore(feedURL: harness.feedURL, cache: cache.appending(path: "harness", directoryHint: .isDirectory), publicKey: key)
        }
        #endif
        return ReleaseNotesStore(feedURL: testFeedURL ?? identity.feed().url, cache: cache)
    }

    /// The notes the changelog page lists: ``releaseNotes``, except that a DEV
    /// build (its bundle names the stable feed, or none, and the stable feed
    /// publishes no notes) lists the cmux-next nightly notes, built
    /// from the same branch: its page shows the newest real notes, not "No
    /// release notes yet" (cx-7rone). Offline with an empty cache the page
    /// keeps that empty state.
    public var changelogNotes: ReleaseNotesStore? {
        guard changelogReadsDevelopmentNotes else { return releaseNotes }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cache = caches.appending(path: "\(identity.bundleIdentifier ?? "cmux")/release-notes/nightly-next", directoryHint: .isDirectory)
        return ReleaseNotesStore(feedURL: Self.developmentNotesFeedURL, cache: cache)
    }

    /// Whether ``changelogNotes`` reads the cmux-next nightly notes (a DEV build
    /// not on the nightly-next feed, no test feed, not a harness copy with notes).
    public var changelogReadsDevelopmentNotes: Bool {
        // A DEV bundle carries the stable feed URL (or none): neither publishes notes.
        guard testFeedURL == nil, identity.track == .development, identity.feed().channel != .nightlyNext else { return false }
        #if DEBUG || CMUX_BENCH_HOOKS
        if UpdateHarness.current?.contentKey != nil { return false }
        #endif
        return true
    }

    /// The cmux-next nightly feed whose `notes/` a DEV build's changelog page reads.
    nonisolated static let developmentNotesFeedURL = "https://files-next.cmux.com/nightly-next/appcast.xml"

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

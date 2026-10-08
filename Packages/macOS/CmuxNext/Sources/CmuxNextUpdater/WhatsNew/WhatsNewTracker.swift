public import Foundation

/// Which What's New documents the user has not seen (pure; decision
/// WHATS-NEW-AFTER-UPDATE W1/W4). `lastSeen` is the newest version whose
/// notes the user opened, or the version first installed.
nonisolated public struct WhatsNewTracker: Sendable, Equatable {
    public var current: WhatsNewVersion
    public var lastSeen: WhatsNewVersion?

    public init(current: WhatsNewVersion, lastSeen: WhatsNewVersion?) {
        self.current = current
        self.lastSeen = lastSeen
    }

    /// Every document after `lastSeen` up to `current` that has entries,
    /// newest first, one per version. None without a `lastSeen` (a fresh
    /// install) or after a downgrade below it.
    public func unseen(_ documents: [WhatsNewDocument]) -> [WhatsNewDocument] {
        guard let lastSeen, lastSeen < current else { return [] }
        return Self.newestFirst(documents.filter { document in
            guard let version = document.parsedVersion, !document.entries.isEmpty else { return false }
            return lastSeen < version && version <= current
        })
    }

    /// The page's content when nothing is unseen (opened from the palette,
    /// the Help menu or `updates.whatsNew`): the newest `limit` documents
    /// with entries up to `current`.
    public func recent(_ documents: [WhatsNewDocument], limit: Int = 3) -> [WhatsNewDocument] {
        Array(Self.newestFirst(documents.filter { document in
            guard let version = document.parsedVersion, !document.entries.isEmpty else { return false }
            return version <= current
        }).prefix(limit))
    }

    /// Newest first; a version that two sources carry keeps the bundled copy.
    static func newestFirst(_ documents: [WhatsNewDocument]) -> [WhatsNewDocument] {
        var byVersion: [WhatsNewVersion: WhatsNewDocument] = [:]
        for document in documents {
            guard let version = document.parsedVersion else { continue }
            if let kept = byVersion[version], kept.origin == .bundled { continue }
            byVersion[version] = document
        }
        return byVersion.sorted { $0.key > $1.key }.map(\.value)
    }
}

/// The persisted half of the tracker: `lastSeen` in the app's defaults
/// (client view state, never the shared tree).
nonisolated public struct WhatsNewSeenStore {
    let defaults: UserDefaults
    static let lastSeenKey = "cmux.next.whatsNew.lastSeenVersion"
    /// The build the retired what's-new card recorded at every launch.
    static let legacyLastSeenBuildKey = "cmux.next.updates.lastSeenBuild"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The tracker for this launch. A first launch with no record is a fresh
    /// install: `current` becomes the baseline, so nothing shows. A record
    /// from the retired card (a build number) reads as that build of the
    /// current version line, so an update right after this change still shows.
    public func tracker(current: WhatsNewVersion) -> WhatsNewTracker {
        if let text = defaults.string(forKey: Self.lastSeenKey), let lastSeen = WhatsNewVersion(text) {
            return WhatsNewTracker(current: current, lastSeen: lastSeen)
        }
        var baseline = current
        if let build = defaults.string(forKey: Self.legacyLastSeenBuildKey), let number = UInt64(build),
           let kind = current.prerelease?.kind {
            baseline.prerelease = (kind, number)
        }
        defaults.set(baseline.description, forKey: Self.lastSeenKey)
        return WhatsNewTracker(current: current, lastSeen: baseline)
    }

    /// The user opened the page: everything up to `version` is seen. Never
    /// moves backward (a rollback keeps the newer record).
    public func markSeen(_ version: WhatsNewVersion) {
        if let text = defaults.string(forKey: Self.lastSeenKey), let stored = WhatsNewVersion(text), stored >= version { return }
        defaults.set(version.description, forKey: Self.lastSeenKey)
    }
}

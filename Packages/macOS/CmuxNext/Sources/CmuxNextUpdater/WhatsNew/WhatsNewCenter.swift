public import Foundation
import Observation

/// What's New after an update (decision WHATS-NEW-AFTER-UPDATE W1): the
/// unseen documents, whether the sidebar shows its What's New item, and
/// the page's content. One per process, owned by the updater.
///
/// The item shows after an update to a version with notes the user has not
/// seen, until the user opens the page; then only the palette, the Help
/// menu and `updates.whatsNew` open it. `updates.showWhatsNew` (default on,
/// managed config can force it off) hides the item.
@MainActor
@Observable
public final class WhatsNewCenter {
    /// Unseen documents, newest first (a multi-version jump shows them all).
    public private(set) var unseen: [WhatsNewDocument] = []
    /// What the page shows: the documents taken when it was last opened.
    public private(set) var presented: [WhatsNewDocument] = []
    /// `updates.showWhatsNew` (set by the App).
    public var isItemEnabled = true
    /// Whether ``load()`` has finished once.
    public private(set) var isLoaded = false

    /// Whether the sidebar's What's New item shows (with its unread dot).
    public var showsItem: Bool { isItemEnabled && !unseen.isEmpty }
    /// This launch is an update the user has not seen: the update the old
    /// app recorded (``lastUpdate``), or a version newer than the last seen
    /// one. Every channel, nightly included (decision D1, 2026-10-10), until
    /// the page opens or the "cmux Updated!" card's x.
    public private(set) var isUpdated = false
    /// Whether the sidebar shows the "cmux Updated!" card: after any update,
    /// with or without notes, until the page opens or the x; never on a
    /// first install. `updates.showWhatsNew` off hides it too.
    public var showsUpdatedCard: Bool { isItemEnabled && isUpdated }
    /// The update this build came from, with its changelog, as the old app
    /// recorded it when the update staged; nil once seen, on a first
    /// install, and after an update the old app did not record.
    public private(set) var lastUpdate: WhatsNewLastUpdate?

    public let current: WhatsNewVersion?
    @ObservationIgnored let seen: WhatsNewSeenStore
    @ObservationIgnored let sources: [any WhatsNewSource]
    /// This launch's `CFBundleVersion` and where the old app left the update record.
    @ObservationIgnored let currentBuild: String
    @ObservationIgnored let lastUpdates: WhatsNewLastUpdateStore?
    @ObservationIgnored private var known: [WhatsNewDocument] = []
    @ObservationIgnored private var tracker: WhatsNewTracker?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// - Parameter currentVersion: this build's `CFBundleShortVersionString`.
    ///   A version the tracker cannot order (a DEV build's "0") shows nothing.
    /// - Parameter lastUpdates: the update record the previous build wrote
    ///   (nil: none is read).
    public init(currentVersion: String, currentBuild: String = "", defaults: UserDefaults, sources: [any WhatsNewSource],
                lastUpdates: WhatsNewLastUpdateStore? = nil) {
        current = WhatsNewVersion(currentVersion)
        self.currentBuild = currentBuild
        seen = WhatsNewSeenStore(defaults: defaults)
        self.sources = sources
        self.lastUpdates = lastUpdates
    }

    /// Reads the record and every source once per launch. Idempotent.
    @discardableResult
    public func load() -> Task<Void, Never> {
        if let loadTask { return loadTask }
        // The record names this build only when this launch is the update it
        // describes; any other record is stale and removed.
        lastUpdate = currentBuild.isEmpty ? nil : lastUpdates?.take(for: currentBuild)
        guard let current else {
            // A version the tracker cannot order (a DEV build): only the record shows.
            isUpdated = lastUpdate != nil
            if let lastUpdate { unseen = [lastUpdate.document] }
            isLoaded = true
            let done = Task<Void, Never> {}
            loadTask = done
            return done
        }
        let tracker = seen.tracker(current: current)
        self.tracker = tracker
        isUpdated = lastUpdate != nil || (tracker.lastSeen.map { $0 < current } ?? false)
        let sources = sources
        let task = Task { [weak self] in
            var documents: [WhatsNewDocument] = []
            // Network sources read only the unseen range; nothing unseen
            // reads their newest few (the page opened from the palette).
            let unseenFloor = tracker.lastSeen.flatMap { $0 < current ? $0 : nil }
            for source in sources {
                documents += await source.documents(after: source.readsNetwork ? unseenFloor : nil, through: current)
            }
            guard let self else { return }
            // The recorded update's changelog stands in for a version with
            // no document of its own (most nightly builds).
            if let record = self.lastUpdate, !documents.contains(where: { $0.version == record.toVersion }) {
                documents.append(record.document)
            }
            self.known = WhatsNewTracker.newestFirst(documents)
            self.unseen = tracker.unseen(self.known)
            if let record = self.lastUpdate, !self.unseen.contains(where: { $0.version == record.toVersion }),
               let document = self.known.first(where: { $0.version == record.toVersion }) {
                // The same short version (a rebuild) is not newer, but the update is unseen.
                self.unseen.insert(document, at: 0)
            }
            self.isLoaded = true
        }
        loadTask = task
        return task
    }

    /// The newest version seen before this launch (read at `load`), the start of the update's
    /// span; nil on a fresh install or before `load`.
    public var lastSeen: WhatsNewVersion? { tracker?.lastSeen }

    /// The page opens (the item, the palette, the Help menu,
    /// `updates.whatsNew`): it shows the unseen documents, or the most
    /// recent ones when nothing is unseen, and everything up to this
    /// version becomes seen. The item goes away; the page keeps its content.
    @discardableResult
    public func open() -> [WhatsNewDocument] {
        let tracker = tracker ?? current.map { WhatsNewTracker(current: $0, lastSeen: $0) }
        presented = unseen.isEmpty ? (tracker?.recent(known) ?? []) : unseen
        if let current { seen.markSeen(current) }
        markRecordSeen()
        unseen = []
        isUpdated = false
        return presented
    }

    /// The update was seen: the record goes, so it shows once.
    private func markRecordSeen() {
        guard lastUpdate != nil else { return }
        lastUpdate = nil
        lastUpdates?.clear()
    }

    /// The "cmux Updated!" card's x: this version is seen, so the card and
    /// the sidebar item's dot go together (one seen state).
    public func dismissUpdated() {
        if let current { seen.markSeen(current) }
        markRecordSeen()
        unseen = []
        isUpdated = false
    }

    /// DEV/NIGHTLY proof (`debug.updater {action: "updated", previous}`):
    /// records `previous` as the last seen version and shows this launch as
    /// an update from it. False for an unreadable or not older version.
    @discardableResult
    public func debugPretendUpdated(from previous: String) -> Bool {
        guard let current, let lastSeen = WhatsNewVersion(previous), lastSeen < current else { return false }
        seen.defaults.set(lastSeen.description, forKey: WhatsNewSeenStore.lastSeenKey)
        let tracker = WhatsNewTracker(current: current, lastSeen: lastSeen)
        self.tracker = tracker
        unseen = tracker.unseen(known)
        isUpdated = true
        return true
    }
}

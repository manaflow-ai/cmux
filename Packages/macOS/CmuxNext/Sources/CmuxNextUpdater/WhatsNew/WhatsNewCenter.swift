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

    public let current: WhatsNewVersion?
    @ObservationIgnored let seen: WhatsNewSeenStore
    @ObservationIgnored let sources: [any WhatsNewSource]
    @ObservationIgnored private var known: [WhatsNewDocument] = []
    @ObservationIgnored private var tracker: WhatsNewTracker?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// - Parameter currentVersion: this build's `CFBundleShortVersionString`.
    ///   A version the tracker cannot order (a DEV build's "0") shows nothing.
    public init(currentVersion: String, defaults: UserDefaults, sources: [any WhatsNewSource]) {
        current = WhatsNewVersion(currentVersion)
        seen = WhatsNewSeenStore(defaults: defaults)
        self.sources = sources
    }

    /// Reads the record and every source once per launch. Idempotent.
    @discardableResult
    public func load() -> Task<Void, Never> {
        if let loadTask { return loadTask }
        guard let current else {
            isLoaded = true
            let done = Task<Void, Never> {}
            loadTask = done
            return done
        }
        let tracker = seen.tracker(current: current)
        self.tracker = tracker
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
            self.known = WhatsNewTracker.newestFirst(documents)
            self.unseen = tracker.unseen(self.known)
            self.isLoaded = true
        }
        loadTask = task
        return task
    }

    /// The page opens (the item, the palette, the Help menu,
    /// `updates.whatsNew`): it shows the unseen documents, or the most
    /// recent ones when nothing is unseen, and everything up to this
    /// version becomes seen. The item goes away; the page keeps its content.
    @discardableResult
    public func open() -> [WhatsNewDocument] {
        let tracker = tracker ?? current.map { WhatsNewTracker(current: $0, lastSeen: $0) }
        presented = unseen.isEmpty ? (tracker?.recent(known) ?? []) : unseen
        if let current { seen.markSeen(current) }
        unseen = []
        return presented
    }
}

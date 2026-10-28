public import CmuxNextDaemon
public import CmuxNextWakeups

/// How the notifications panel follows the daemon's ledger (plans/cmux-next/chrome-parity/
/// p06-scheduler.md, task 205): only while it shows. ``open()`` makes its node visible, loads once
/// and follows the ledger state (``Mark``) through a ``VisibleObservation`` on that node, one read
/// per frame however many notifications came; ``close()`` stops the observation and hides the
/// node, so a closed panel reads nothing.
@MainActor
public final class NotificationsPanelLedgerWatch {
    /// What makes the open panel read the ledger again: the newest notification and the unread count.
    public nonisolated struct Mark: Equatable, Sendable {
        /// The newest notification's id; 0 with none.
        public var newest: UInt64
        /// The unread badge count.
        public var unread: Int

        /// The ledger state of `store` now.
        @MainActor public init(_ store: DaemonStore) {
            newest = store.notifications.last?.notification.rawValue ?? 0
            unread = store.unreadBadge()
        }
    }

    /// Visible while the panel shows, hidden from its close.
    public let node: VisibilityNode
    private let store: DaemonStore
    private let work: MainWorkScheduler
    private var watch: VisibleObservation<Mark>?
    /// The ledger state the last load read.
    private var loadedMark: Mark?
    /// Loads the panel's rows (the panel's reload, which calls ``noteLoaded()``).
    public var onChange: (@MainActor () -> Void)?
    /// Ledger state reads of the observation (tests: a closed panel reads none).
    public private(set) var reads = 0
    /// Loads the panel started (``noteLoaded()``).
    public private(set) var loads = 0

    /// - Parameters:
    ///   - node: The panel's node (its rows hang under it).
    ///   - store: The local daemon's store, whose ledger the panel lists.
    ///   - work: The app's main-thread scheduler.
    public init(node: VisibilityNode, store: DaemonStore, work: MainWorkScheduler) {
        self.node = node
        self.store = store
        self.work = work
    }

    /// The panel shows: its node is visible, it loads once and then follows the ledger.
    public func open() {
        node.set(.visible)
        onChange?()
        watch?.cancel()
        let store = self.store
        watch = VisibleObservation(node, owner: "notifications.panel.ledger", on: work) { [weak self] () -> Mark in
            self?.reads += 1
            return Mark(store)
        } apply: { [weak self] mark in
            guard let self, mark != self.loadedMark else { return }
            self.onChange?()
        }
    }

    /// The panel closes: no read and no load until it opens again.
    public func close() {
        watch?.cancel()
        watch = nil
        node.set(.hidden)
    }

    /// The panel loads the ledger now: the state it reads is the one a change is compared with.
    public func noteLoaded() {
        loadedMark = Mark(store)
        loads += 1
    }
}

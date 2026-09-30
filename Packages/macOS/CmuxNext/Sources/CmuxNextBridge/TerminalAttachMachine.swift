public import CmuxNextDaemon
public import Foundation

/// The lifecycle of one terminal view's daemon attachment, as one pure state
/// machine (plans/cmux-next/state-audit.md T3-T5).
///
/// ```
/// detached ─start─▶ attaching ─opened─▶ attaching(link) ─replay─▶ live
///                        ▲                                          │
///                        └──────── reattaching ◀── overflow ────────┘
/// any ─close / terminal failure─▶ closed
/// ```
///
/// Rules the reducer enforces, whatever order events arrive in:
/// - Input typed before the replay (first attach or reattach) is queued and
///   sent once, in order, right after the replay. Input never goes to a link
///   that has not delivered its replay or that has ended.
/// - Grid reports before the replay are coalesced: only the latest size is
///   sent, after the replay, followed by the geometry claim when visible.
/// - Every link that was opened is detached exactly once: on overflow, on
///   close, or when its open completes after the machine moved on.
///
/// `Link` identifies an open attachment; the driver owns the real object.
/// Effects must be applied in the order returned, and batches in the order
/// the reducer produced them (``TerminalAttachDriver`` does both).
public nonisolated struct TerminalAttachMachine<Link: Hashable & Sendable>: Sendable {
    /// An attach in flight: `link` is nil until the open completes, then the
    /// machine waits for that link's replay.
    public struct Pending: Hashable, Sendable {
        /// Unique per open, so a late completion never matches a newer one.
        public var attempt: Int
        /// Consecutive attaches that have not reached `live`, this one included.
        public var failures: Int
        public var size: CellSize
        public var link: Link?
    }

    public enum Phase: Hashable, Sendable {
        case detached
        case attaching(Pending)
        case live(Link)
        case reattaching(Pending)
        case closed
    }

    public enum Event: Hashable, Sendable {
        case start
        /// The open for `attempt` returned `link`.
        case opened(Link, attempt: Int)
        /// The open for `attempt` failed.
        case openFailed(attempt: Int)
        /// `link`'s replay reached the consumer.
        case replayDelivered(Link)
        /// Encoded user input from the surface.
        case input(Data)
        /// The view's settled grid.
        case resize(CellSize)
        /// The surface started or stopped rendering (SurfaceLedger).
        case visibility(Bool)
        /// The surface gained keyboard focus.
        case focused
        /// `link`'s stream announced the PTY grid (a daemon `resized`).
        case gridAnnounced(Link, CellSize)
        /// `link`'s stream ended.
        case ended(Link, TerminalChannelCloseReason)
        /// The tab closed or the view was dropped.
        case close
    }

    public enum Effect: Hashable, Sendable {
        /// Open a new attachment at `size`; report `.opened` or `.openFailed`.
        /// An open is never abandoned mid-handshake: when the machine moved
        /// on, the link it returns is detached at once, with its lease, so
        /// the daemon frees the view attachment explicitly.
        case open(attempt: Int, size: CellSize)
        case send(Link, Data)
        /// Passive grid report on `link`.
        case resize(Link, CellSize)
        /// Report `size` on `link`, then claim canonical geometry.
        case claim(Link, CellSize)
        case release(Link)
        case detach(Link)
        /// End the consumer's stream.
        case finish
    }

    /// Consecutive attaches that may fail to reach `live` before giving up.
    public static var maxAttempts: Int { 8 }
    /// Input held while attaching. Beyond it new input is dropped and counted.
    public static var maxQueuedInputBytes: Int { 4 << 20 }

    public private(set) var phase: Phase = .detached
    public private(set) var queuedInput: [Data] = []
    public private(set) var queuedInputBytes = 0
    /// Input dropped: over the queue cap, or typed after the attachment ended for good.
    public private(set) var droppedInputBytes = 0
    /// Latest settled grid (coalesced).
    public private(set) var desiredSize: CellSize?
    public private(set) var visible: Bool
    /// Size last reported on the live link (nil after a release or a new link).
    public private(set) var reportedSize: CellSize?
    /// True when the live link holds the geometry claim.
    public private(set) var claimed = false
    private let initialSize: CellSize
    private var lastAttempt = 0

    public init(initialSize: CellSize, visible: Bool = true) {
        self.initialSize = initialSize
        self.visible = visible
    }

    /// The link input goes to right now, if any.
    public var liveLink: Link? {
        if case .live(let link) = phase { return link }
        return nil
    }

    public var isClosed: Bool { phase == .closed }

    public mutating func reduce(_ event: Event) -> [Effect] {
        switch event {
        case .start: start()
        case .opened(let link, let attempt): opened(link, attempt: attempt)
        case .openFailed(let attempt): openFailed(attempt: attempt)
        case .replayDelivered(let link): replayDelivered(link)
        case .input(let data): input(data)
        case .resize(let size): resize(size)
        case .visibility(let visible): setVisible(visible)
        case .focused: []
        case .gridAnnounced: []
        case .ended(let link, let reason): ended(link, reason: reason)
        case .close: close()
        }
    }

    // MARK: Transitions

    private mutating func start() -> [Effect] {
        guard phase == .detached else { return [] }
        let pending = newPending(failures: 1)
        phase = .attaching(pending)
        return [.open(attempt: pending.attempt, size: pending.size)]
    }

    private mutating func opened(_ link: Link, attempt: Int) -> [Effect] {
        guard var pending = pendingAttach, pending.attempt == attempt, pending.link == nil else {
            // Closed meanwhile, or a superseded attempt: free it now.
            return [.detach(link)]
        }
        pending.link = link
        setPending(pending)
        return []
    }

    private mutating func openFailed(attempt: Int) -> [Effect] {
        guard let pending = pendingAttach, pending.attempt == attempt, pending.link == nil else { return [] }
        return terminate(detaching: nil)
    }

    private mutating func replayDelivered(_ link: Link) -> [Effect] {
        guard let pending = pendingAttach, pending.link == link else { return [] }
        phase = .live(link)
        // The attach itself reported the size it opened with.
        reportedSize = pending.size
        claimed = false
        var effects = syncGeometry(link)
        effects += queuedInput.map { .send(link, $0) }
        queuedInput = []
        queuedInputBytes = 0
        return effects
    }

    private mutating func input(_ data: Data) -> [Effect] {
        guard !data.isEmpty else { return [] }
        switch phase {
        case .live(let link):
            return [.send(link, data)]
        case .closed:
            droppedInputBytes += data.count
            return []
        case .detached, .attaching, .reattaching:
            guard queuedInputBytes + data.count <= Self.maxQueuedInputBytes else {
                droppedInputBytes += data.count
                return []
            }
            queuedInput.append(data)
            queuedInputBytes += data.count
            return []
        }
    }

    private mutating func resize(_ size: CellSize) -> [Effect] {
        guard size.cols > 0, size.rows > 0 else { return [] }
        desiredSize = size
        guard let link = liveLink else { return [] }
        return syncGeometry(link)
    }

    private mutating func setVisible(_ visible: Bool) -> [Effect] {
        guard self.visible != visible else { return [] }
        self.visible = visible
        guard let link = liveLink else { return [] }
        if !visible {
            guard claimed || reportedSize != nil else { return [] }
            claimed = false
            reportedSize = nil
            return [.release(link)]
        }
        return syncGeometry(link)
    }

    private mutating func ended(_ link: Link, reason: TerminalChannelCloseReason) -> [Effect] {
        let current: Link?
        let failures: Int
        switch phase {
        case .live(let live):
            current = live
            failures = 0
        case .attaching(let pending), .reattaching(let pending):
            current = pending.link
            failures = pending.failures
        case .detached, .closed:
            return []
        }
        guard current == link else { return [] }
        guard reason == .overflow, failures < Self.maxAttempts else {
            return terminate(detaching: link)
        }
        // This view fell behind: drop the link and attach again for a fresh
        // replay. Input typed meanwhile queues until that replay.
        let pending = newPending(failures: failures + 1)
        phase = .reattaching(pending)
        claimed = false
        reportedSize = nil
        return [.detach(link), .open(attempt: pending.attempt, size: pending.size)]
    }

    private mutating func close() -> [Effect] {
        switch phase {
        case .closed:
            return []
        case .detached:
            return terminate(detaching: nil)
        case .live(let link):
            return terminate(detaching: link)
        case .attaching(let pending), .reattaching(let pending):
            // An open still in flight is detached when it completes (`opened`).
            return terminate(detaching: pending.link)
        }
    }

    // MARK: Helpers

    private var pendingAttach: Pending? {
        switch phase {
        case .attaching(let pending), .reattaching(let pending): pending
        default: nil
        }
    }

    private mutating func newPending(failures: Int) -> Pending {
        lastAttempt += 1
        return Pending(attempt: lastAttempt, failures: failures, size: desiredSize ?? initialSize, link: nil)
    }

    private mutating func setPending(_ pending: Pending) {
        if case .reattaching = phase { phase = .reattaching(pending) } else { phase = .attaching(pending) }
    }

    /// Brings the live link's geometry in line with the desired size and
    /// visibility: a visible view reports its latest grid and claims.
    private mutating func syncGeometry(_ link: Link) -> [Effect] {
        guard visible, let size = desiredSize else { return [] }
        if !claimed {
            claimed = true
            reportedSize = size
            return [.claim(link, size)]
        }
        guard reportedSize != size else { return [] }
        reportedSize = size
        return [.resize(link, size)]
    }

    private mutating func terminate(detaching link: Link?) -> [Effect] {
        phase = .closed
        droppedInputBytes += queuedInputBytes
        queuedInput = []
        queuedInputBytes = 0
        claimed = false
        reportedSize = nil
        return (link.map { [Effect.detach($0)] } ?? []) + [.finish]
    }
}

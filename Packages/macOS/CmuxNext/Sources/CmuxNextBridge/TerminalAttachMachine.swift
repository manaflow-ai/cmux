public import CmuxNextDaemon
public import Foundation

/// The lifecycle of one terminal view's daemon attachment, as one pure state
/// machine (plans/cmux-next/state-audit.md T3-T5).
///
/// ```
/// detached ─start─▶ attaching ─opened─▶ attaching(link) ─replay─▶ live
///                        ▲                                          │
///                        └──────── reattaching ◀── overflow ────────┘
/// stream ended / attach failed ─▶ disconnected ─event─▶ reattaching
/// any ─processExited─▶ exited        any ─close─▶ closed
/// ```
///
/// A view is never closed because its stream ended or an attach failed: it
/// is `disconnected`, keeps its last screen, and re-attaches on the next
/// event that can make an attach work (shown again, a key press, a click or
/// focus, the terminal or the connection back). One re-attach at a time. A
/// re-attach after a failed re-attach waits the capped backoff first
/// (`openAfterBackoff`); nothing retries on a timer. A terminal whose
/// process ended is `exited` and never re-attaches.
///
/// Rules the reducer enforces, whatever order events arrive in:
/// - Input typed before the replay (first attach or reattach) is queued and
///   sent once, in order, right after the replay. Input never goes to a link
///   that has not delivered its replay or that has ended.
/// - Grid reports before the replay are coalesced: only the latest size is
///   sent, after the replay, followed by the geometry claim when visible.
/// - Every link that was opened is detached exactly once: on overflow, on
///   close, or when its open completes after the machine moved on.
/// - Geometry follows the latest active client: the most recently active
///   client holds it. A visible view claims when it is shown, on every
///   settled resize, and, after the stream announced a grid other than the
///   one it reported (another client sized the terminal), on its next key
///   press or focus. A hidden view never claims.
///
/// `Link` identifies an open attachment; the driver owns the real object.
/// Effects must be applied in the order returned, and batches in the order
/// the reducer produced them (``TerminalAttachDriver`` does both).
public nonisolated struct TerminalAttachMachine<Link: Hashable & Sendable>: Sendable {
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
    /// True while this view believes it holds geometry: it claimed, and the
    /// stream has not announced another client's grid since.
    public private(set) var claimed = false
    /// Last status the view was told (it starts connected: nothing shown).
    public private(set) var status: LinkStatus = .connected
    /// The process ended while an attach was pending: its replay (the last
    /// screen) still lands, then the view is exited.
    public private(set) var exitAfterReplay = false
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
        case .focused: focused()
        case .gridAnnounced(let link, let size): gridAnnounced(link, size: size)
        case .ended(let link, let reason): ended(link, reason: reason)
        case .reconnect: reconnect()
        case .processExited: processExited()
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
        if exitAfterReplay {
            phase = .detached
            return processExited()
        }
        return disconnect(.attachFailed, after: pending)
    }

    private mutating func replayDelivered(_ link: Link) -> [Effect] {
        guard let pending = pendingAttach, pending.link == link else { return [] }
        if exitAfterReplay {
            phase = .live(link)
            return processExited()
        }
        phase = .live(link)
        // The attach itself reported the size it opened with.
        reportedSize = pending.size
        claimed = false
        var effects = announce(.connected)
        effects += syncGeometry(link)
        effects += queuedInput.map { .send(link, $0) }
        queuedInput = []
        queuedInputBytes = 0
        return effects
    }

    private mutating func input(_ data: Data) -> [Effect] {
        guard !data.isEmpty else { return [] }
        switch phase {
        case .live(let link):
            // Geometry first, so the program sees this view's width before the key.
            return reclaim() + [.send(link, data)]
        case .closed, .exited:
            droppedInputBytes += data.count
            return []
        case .detached, .attaching, .reattaching, .disconnected:
            guard queuedInputBytes + data.count <= Self.maxQueuedInputBytes else {
                droppedInputBytes += data.count
                return []
            }
            queuedInput.append(data)
            queuedInputBytes += data.count
            // A key press in a disconnected view re-attaches; the keys go
            // after the replay.
            return reconnect()
        }
    }

    private mutating func resize(_ size: CellSize) -> [Effect] {
        guard size.cols > 0, size.rows > 0 else { return [] }
        let changed = desiredSize != size
        desiredSize = size
        guard let link = liveLink, visible else { return [] }
        // A visible pane that resized takes geometry back, whoever held it.
        guard changed || !claimed || reportedSize != size else { return [] }
        return claim(link, size)
    }

    /// The stream announced `size`. Another client's grid means this view no
    /// longer holds geometry; its next key press or focus claims again. A
    /// grid from this view's earlier report (announced after a newer one)
    /// costs at most one redundant claim.
    private mutating func gridAnnounced(_ link: Link, size: CellSize) -> [Effect] {
        guard liveLink == link, claimed, size != reportedSize else { return [] }
        claimed = false
        return []
    }

    /// Focus or a click: a disconnected view re-attaches; a live one takes
    /// geometry back.
    private mutating func focused() -> [Effect] {
        if case .disconnected = phase { return reconnect() }
        return reclaim()
    }

    /// Key press or focus: a visible view that lost geometry takes it back.
    private mutating func reclaim() -> [Effect] {
        guard let link = liveLink, visible, !claimed, let size = desiredSize else { return [] }
        return claim(link, size)
    }

    private mutating func setVisible(_ visible: Bool) -> [Effect] {
        guard self.visible != visible else { return [] }
        self.visible = visible
        if visible, case .disconnected = phase { return reconnect() }
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
        case .detached, .disconnected, .exited, .closed:
            return []
        }
        guard current == link else { return [] }
        guard reason == .overflow, failures < Self.maxAttempts else {
            let mapped: DisconnectReason = switch reason {
            case .overflow: .fellBehind
            case .connectionLost: .connectionLost
            case .surfaceGone, .detachedByClient: .streamEnded
            }
            if exitAfterReplay {
                phase = .detached
                return [.detach(link)] + processExited()
            }
            return [.detach(link)] + disconnect(mapped, after: pendingAttach)
        }
        // This view fell behind: drop the link and attach again for a fresh
        // replay. Input typed meanwhile queues until that replay.
        let pending = newPending(failures: failures + 1)
        phase = .reattaching(pending)
        claimed = false
        reportedSize = nil
        return [.detach(link), .open(attempt: pending.attempt, size: pending.size)]
    }

    /// Starts one re-attach of a disconnected view. Anything else (an attach
    /// already pending, a live, exited or closed view) ignores it.
    private mutating func reconnect() -> [Effect] {
        guard case .disconnected(let disconnected) = phase else { return [] }
        lastAttempt += 1
        let pending = Pending(attempt: lastAttempt, failures: 1, size: desiredSize ?? initialSize, link: nil,
                              reconnects: disconnected.failedReconnects)
        phase = .reattaching(pending)
        let open: Effect = disconnected.failedReconnects == 0
            ? .open(attempt: pending.attempt, size: pending.size)
            : .openAfterBackoff(attempt: pending.attempt, size: pending.size, failedReconnects: disconnected.failedReconnects)
        return announce(.disconnected(disconnected.reason, reconnecting: true)) + [open]
    }

    /// The attach (or the stream) failed: keep the last screen and queued
    /// input and wait for an event. A failed re-attach counts toward the
    /// backoff of the next one.
    private mutating func disconnect(_ reason: DisconnectReason, after pending: Pending?) -> [Effect] {
        let failed = pending?.reconnects.map { $0 + 1 } ?? 0
        phase = .disconnected(Disconnected(reason: reason, failedReconnects: failed))
        claimed = false
        reportedSize = nil
        return announce(.disconnected(reason, reconnecting: false))
    }

    private mutating func processExited() -> [Effect] {
        let link: Link?
        switch phase {
        case .exited, .closed: return []
        case .live(let live): link = live
        case .attaching, .reattaching:
            // Let the pending replay show the last screen first.
            exitAfterReplay = true
            return []
        case .detached, .disconnected: link = nil
        }
        phase = .exited
        droppedInputBytes += queuedInputBytes
        queuedInput = []
        queuedInputBytes = 0
        claimed = false
        reportedSize = nil
        return (link.map { [Effect.detach($0)] } ?? []) + announce(.exited)
    }

    private mutating func announce(_ status: LinkStatus) -> [Effect] {
        guard self.status != status else { return [] }
        self.status = status
        return [.status(status)]
    }

    private mutating func close() -> [Effect] {
        switch phase {
        case .closed:
            return []
        case .detached, .disconnected, .exited:
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
        guard visible, let size = desiredSize, !claimed || reportedSize != size else { return [] }
        return claim(link, size)
    }

    private mutating func claim(_ link: Link, _ size: CellSize) -> [Effect] {
        claimed = true
        reportedSize = size
        return [.claim(link, size)]
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

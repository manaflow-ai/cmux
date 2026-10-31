public import CmuxNextDaemon
public import Foundation

/// The lifecycle of one terminal view's daemon attachment, as one pure state
/// machine (plans/cmux-next/state-audit.md T3-T5).
///
/// ```
/// detached ─start─▶ attaching ─opened─▶ attaching(link) ─replay─▶ live
///                        ▲                                          │
///                        └──────── reattaching ◀── overflow ────────┘
/// stream ended / attach failed ─▶ disconnected ─event or retry─▶ reattaching
/// any ─processExited─▶ exited        any ─close─▶ closed
/// exited ─processRevived─▶ reattaching
/// ```
///
/// A view is never closed because its stream ended or an attach failed: it
/// is `disconnected`, keeps its last screen, and re-attaches. A visible view
/// retries by itself (cx-wwtam), each re-attach after the capped backoff
/// (`openAfterBackoff`), for as long as it stays visible, so a terminal whose
/// daemon answers late or refused its connection for a while comes back with
/// no user input. While hidden it re-attaches on the next event that can make
/// an attach work (shown again, a key press, a click or focus, the terminal
/// or the connection back). After ``quietReconnects`` self-started ones the
/// view keeps retrying but says the attach failed, so Retry shows (and a
/// restored view stops saying `restoring`). One re-attach at a time. Until a view first went
/// live its status is `restoring` (when it was created as a restore) while it
/// attaches or retries, and its backoff stays short (``restoreBackoffCap``), so it comes
/// back with no input soon after the daemon answers (#23029). An event that comes while an
/// attach is in flight is kept: if that attach fails, the next one opens at once. A terminal whose
/// process ended is `exited` and never re-attaches on a view event; only the
/// daemon reporting the terminal running again (`processRevived`) re-attaches
/// it, because a dead report can be transient (R41).
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
    /// Self-started re-attaches in a row (about 90 s with the App's backoff)
    /// before the view, still retrying, offers Retry: its status says the
    /// attach failed and that a click or key re-attaches now.
    public static var quietReconnects: Int { 8 }
    /// The backoff step a restored view that has not gone live yet waits at
    /// most (2 s with the App's backoff): it says "Restoring…", and only its
    /// own retry or an event (a key, focus, the connection back) wakes it, so
    /// it must not wait 30 s for an attach that would now work (#23029).
    public static var restoreBackoffCap: Int { 3 }
    /// ``quietReconnects`` for that view: about the same 90 s at its shorter backoff. Past it the
    /// view offers Retry and backs off as any other, so a daemon that never answers is not asked
    /// every 2 s for good.
    public static var quietRestoreReconnects: Int { 45 }

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
    /// The link this view hid on (`.hide`); showing the view again un-hides it there.
    private var hiddenOn: Link?
    /// This view's claims the stream has not echoed yet, oldest first (a live resize claims every frame).
    public private(set) var echoesDue: [CellSize] = []
    /// The grid the stream last announced on the live link: a claim of it changes nothing, so the
    /// stream echoes nothing and no echo is due (a stale one held the next drag's grids).
    public private(set) var announcedSize: CellSize?
    /// Last status the view was told (it starts connected: nothing shown).
    public private(set) var status: LinkStatus = .connected
    /// The process ended while an attach was pending: its replay (the last
    /// screen) still lands, then the view is exited.
    public private(set) var exitAfterReplay = false
    /// A replay reached this view at least once.
    public private(set) var wentLive = false
    /// Re-attaches the view started by itself since the last event.
    public private(set) var autoReconnects = 0
    /// Why the view last disconnected (the status of a re-attach an event cuts short).
    private var lastDisconnect: DisconnectReason = .attachFailed
    /// An event that re-attaches (the connection back, a key, focus) came while an attach was
    /// in flight: if that attach fails, the next one opens at once instead of after the backoff.
    private var reattachRequested = false
    private let initialSize: CellSize
    private let restoring: Bool
    private var lastAttempt = 0

    /// `restoring`: the view attaches to a terminal that already runs (a
    /// relaunch or a reopened tab), so it says `restoring` until its first
    /// replay instead of nothing.
    public init(initialSize: CellSize, visible: Bool = true, restoring: Bool = false) {
        self.initialSize = initialSize
        self.visible = visible
        self.restoring = restoring
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
        case .takeOver(let setLatest): takeOver(setLatest: setLatest)
        case .gridAnnounced(let link, let size): gridAnnounced(link, size: size)
        case .ended(let link, let reason): ended(link, reason: reason)
        case .reconnect: reconnect()
        case .processExited: processExited()
        case .processRevived: processRevived()
        case .close: close()
        }
    }

    // MARK: Transitions

    private mutating func start() -> [Effect] {
        guard phase == .detached else { return [] }
        let pending = newPending(failures: 1)
        phase = .attaching(pending)
        return (restoring ? announce(.restoring) : []) + [.open(attempt: pending.attempt, size: pending.size)]
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
        wentLive = true
        reattachRequested = false
        // The attach itself reported the size it opened with.
        reportedSize = pending.size
        claimed = false
        var effects = announce(.connected)
        // Hidden while it attached (a background tab, a re-attach while parked): the size its attach
        // reported does not count toward the grid.
        if !visible {
            hiddenOn = link
            effects.append(.hide(link))
        }
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

    /// The stream announced `size`. Another client's grid means this view no longer holds
    /// geometry; its next key press or focus claims again. Its own earlier reports are not.
    private mutating func gridAnnounced(_ link: Link, size: CellSize) -> [Effect] {
        // A pending attach's own grid is the daemon's grid too: its replay's claim of that size waits for no echo.
        if pendingAttach?.link == link { announcedSize = size; return [] }
        guard liveLink == link else { return [] }
        announcedSize = size
        if let mine = echoesDue.firstIndex(of: size) { echoesDue.removeFirst(mine + 1); return [] }
        guard claimed, size != reportedSize else { return [] }
        claimed = false; echoesDue = []
        return []
    }

    /// Focus or a click: a disconnected view re-attaches; a live one takes
    /// geometry back.
    private mutating func focused() -> [Effect] {
        if liveLink == nil { return reconnect() }
        return reclaim()
    }

    /// Take over always sends: under `priority` a claim that did not win changes no grid, so
    /// `claimed` stays set and `reclaim` would send nothing on the next click.
    private mutating func takeOver(setLatest: Bool) -> [Effect] {
        if liveLink == nil { return reconnect() }
        guard let link = liveLink, visible, let size = desiredSize else { return [] }
        // The bookkeeping of a claim (claimed, reported size, echo due); the effect also claims.
        _ = claim(link, size)
        return [.takeOver(link, size, setLatest: setLatest)]
    }

    /// Key press or focus: a visible view that lost geometry takes it back.
    private mutating func reclaim() -> [Effect] {
        guard let link = liveLink, visible, !claimed, let size = desiredSize else { return [] }
        return claim(link, size)
    }

    private mutating func setVisible(_ visible: Bool) -> [Effect] {
        guard self.visible != visible else { return [] }
        self.visible = visible
        // Shown again: a disconnected view re-attaches, one waiting out a backoff now.
        if visible, liveLink == nil { return reconnect() }
        guard let link = liveLink else { return [] }
        if !visible {
            // The claim stays: hidden, the view only stops counting toward the grid (no PTY resize,
            // no report or claim to show it again). Another client's grid meanwhile clears `claimed`.
            guard claimed || reportedSize != nil else { return [] }
            hiddenOn = link
            return [.hide(link)]
        }
        let unhide: [Effect] = hiddenOn == link ? [.unhide(link)] : []
        hiddenOn = nil
        return unhide + syncGeometry(link)
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
        claimed = false; reportedSize = nil; echoesDue = []; announcedSize = nil; hiddenOn = nil
        return [.detach(link), .open(attempt: pending.attempt, size: pending.size)]
    }

    /// Starts one re-attach of a disconnected view. Anything else (an attach
    /// already pending, a live, exited or closed view) ignores it.
    ///
    /// An event (a key, focus, shown again, Retry, the terminal or the
    /// connection back) opens at once and restarts its backoff;
    /// it also cuts short a self-started re-attach still waiting out its
    /// backoff (that attempt's late open is then detached as superseded).
    /// A self-started one waits the backoff for the larger of the failed
    /// re-attaches and the self-started ones before it, so a link that goes
    /// live and drops again and again still slows down to the capped wait.
    private mutating func reconnect(byEvent: Bool = true) -> [Effect] {
        let reason: DisconnectReason
        let failed: Int
        switch phase {
        case .disconnected(let disconnected):
            reason = disconnected.reason
            failed = disconnected.failedReconnects
        case .reattaching(let pending) where byEvent && pending.link == nil && pending.waitsBackoff:
            reason = lastDisconnect
            failed = 0
        case .attaching, .reattaching:
            // An attach is in flight: the event must not be lost if it fails (`disconnect`).
            if byEvent { reattachRequested = true }
            return []
        default:
            return []
        }
        if byEvent { autoReconnects = 0 }
        reattachRequested = false
        let stillRestoring = restoring && !wentLive
        var wait = byEvent ? 0 : max(failed, autoReconnects - 1)
        if stillRestoring, autoReconnects <= Self.quietRestoreReconnects { wait = min(wait, Self.restoreBackoffCap) }
        lastAttempt += 1
        var pending = Pending(attempt: lastAttempt, failures: 1, size: desiredSize ?? initialSize, link: nil,
                              reconnects: byEvent ? 0 : failed)
        pending.waitsBackoff = wait > 0
        phase = .reattaching(pending)
        lastDisconnect = reason
        let open: Effect = wait == 0
            ? .open(attempt: pending.attempt, size: pending.size)
            : .openAfterBackoff(attempt: pending.attempt, size: pending.size, failedReconnects: wait)
        let quiet = stillRestoring ? Self.quietRestoreReconnects : Self.quietReconnects
        let status: LinkStatus = if !byEvent, autoReconnects > quiet {
            .disconnected(reason, reconnecting: false)
        } else if stillRestoring {
            .restoring
        } else {
            .disconnected(reason, reconnecting: true)
        }
        return announce(status) + [open]
    }

    /// The attach (or the stream) failed: keep the last screen and queued
    /// input. A visible view re-attaches by itself after the backoff, which
    /// caps at the App's maximum; a hidden one waits for an event. A failed
    /// re-attach counts toward the backoff of the next one.
    private mutating func disconnect(_ reason: DisconnectReason, after pending: Pending?) -> [Effect] {
        let failed = pending?.reconnects.map { $0 + 1 } ?? 0
        phase = .disconnected(Disconnected(reason: reason, failedReconnects: failed))
        claimed = false; reportedSize = nil; echoesDue = []; announcedSize = nil; hiddenOn = nil
        // The connection came back (or a key or focus) while this attach was in flight.
        if reattachRequested { return reconnect() }
        if visible, reason != .fellBehind {
            autoReconnects += 1
            return reconnect(byEvent: false)
        }
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
        claimed = false; reportedSize = nil; echoesDue = []; announcedSize = nil; hiddenOn = nil
        return (link.map { [Effect.detach($0)] } ?? []) + announce(.exited)
    }

    /// The daemon reports the terminal running after it reported it dead.
    /// A pending exit is withdrawn; an exited view attaches again for a fresh
    /// replay. A live or disconnected view is unaffected (the App's
    /// `reconnect` covers a disconnected one).
    private mutating func processRevived() -> [Effect] {
        switch phase {
        case .attaching, .reattaching:
            exitAfterReplay = false
            return []
        case .exited:
            exitAfterReplay = false
            phase = .disconnected(Disconnected(reason: .streamEnded, failedReconnects: 0))
            return reconnect()
        case .disconnected:
            return reconnect()
        case .detached, .live, .closed:
            return []
        }
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
        if size != announcedSize || !echoesDue.isEmpty { echoesDue = Array((echoesDue + [size]).suffix(8)) }
        return [.claim(link, size)]
    }

    private mutating func terminate(detaching link: Link?) -> [Effect] {
        phase = .closed
        droppedInputBytes += queuedInputBytes
        queuedInput = []
        queuedInputBytes = 0
        claimed = false; reportedSize = nil; echoesDue = []; announcedSize = nil; hiddenOn = nil
        return (link.map { [Effect.detach($0)] } ?? []) + [.finish]
    }
}

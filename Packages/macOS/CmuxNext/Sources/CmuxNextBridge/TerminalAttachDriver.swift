public import CmuxNextDaemon
public import CmuxNextInputModel
public import Foundation
import CmuxNextCompat

/// One open daemon attachment as the driver uses it. Every command is a
/// synchronous, nonblocking send, so the driver applies effects in order
/// without hopping between tasks (state-audit.md T4).
public nonisolated protocol TerminalAttachLink: AnyObject, Sendable {
    /// `replay -> (output | resized | …)* -> closed`, finishing after `closed`.
    var events: AsyncStream<TerminalChannelEvent> { get }
    /// Sends input; `keyFlow` is the latency slot flow of the key press the bytes encode (0: none).
    func sendInput(_ data: Data, keyFlow: UInt64)
    /// Reports `size`, then claims canonical geometry.
    func sendClaim(reporting size: CellSize)
    /// Take over: optionally sets the terminal's policy to last active, then reports `size` and claims.
    func sendTakeOver(reporting size: CellSize, setLatest: Bool)
    /// The view hid or shows again; hidden, it keeps its lease and claim and stops counting toward the grid.
    func sendHidden(_ hidden: Bool)
    /// Asks for a fresh READY + history on this attach.
    func sendSnapshotRequest(reason: SnapshotRequestReason)
    /// Live output goes from the link's reader straight to `sink`, in order with `events` (each change waits
    /// for an ``TerminalChannelEvent/outputResume(_:)`` marker); nil keeps it on `events`.
    func setOutputSink(_ sink: TerminalEchoSink?)
    /// Detaches and closes the connection; its `events` then finish.
    /// Idempotent.
    func detachNow()
    /// Ranks the link's stream against the other views of its connection (`set-stream-priority`).
    func sendStreamPriority(_ priority: TerminalStreamPriority)
}

public nonisolated extension TerminalAttachLink {
    /// A link with no stream to rank.
    func sendStreamPriority(_ priority: TerminalStreamPriority) {}
}

/// Runs a ``TerminalAttachMachine`` against real attachments: one reducer
/// under one lock, one effect applier, and one pump per open link feeding a
/// bounded ``TerminalStepQueue``. Live output skips the pump once the view
/// names its lane (``setOutputSink(_:)``): the link's reader hands it to the
/// lane, behind every step the view has not applied yet.
///
/// Effects are applied outside the lock but strictly in the order the
/// reducer produced them: whichever caller finds the applier idle drains the
/// outbox (including effects other threads add meanwhile) until it is empty.
/// Input, grid reports, visibility and close may therefore come from any
/// thread; their daemon commands still go out in reduction order.
public nonisolated final class TerminalAttachDriver<Link: TerminalAttachLink>: Sendable {
    public typealias Opener = @Sendable (CellSize) async throws -> Link
    public typealias Machine = TerminalAttachMachine<LinkRef>
    /// Sees every reduced event and the machine it produced, in reduction
    /// order, under the reducer's lock (the input journal). Must not block.
    public typealias Observer = @Sendable (Machine.Event, Machine) -> Void

    /// Identity wrapper so the pure machine can compare links.
    public struct LinkRef: Hashable, Sendable {
        public let link: Link
        public static func == (lhs: LinkRef, rhs: LinkRef) -> Bool { lhs.link === rhs.link }
        public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(link)) }
    }

    /// An effect the applier sends, with the key flow of the input that made it (0: none).
    private struct Outgoing {
        var effect: Machine.Effect
        var keyFlow: UInt64 = 0
    }

    private struct Core {
        var machine: Machine
        var outbox: [Outgoing] = []
        var applying = false
        /// One task per attach attempt: opens the link, then pumps it.
        var tasks: [Int: Task<Void, Never>] = [:]
        /// The view's output lane (``setOutputSink(_:)``), and the links being pumped, which carry it.
        var sink: TerminalEchoSink?
        var pumped: [Int: LinkRef] = [:]
        /// The priority every pumped link has (``TerminalStreamPriority``), from `machine.visible` and whether
        /// this view holds ``streamFocus``.
        var streamPriority: TerminalStreamPriority
        /// Links are ranked: the driver has a ``TerminalStreamFocus`` (feature `terminalStreamPriority`).
        let ranksStreams: Bool
    }

    private let core: Mutex<Core>
    private let queue: TerminalStepQueue
    private let opener: Opener
    private let onFailure: @Sendable (any Error) -> Void
    private let onReattach: @Sendable (Int) -> Void
    private let observer: Observer?
    private let cursorDefault: TerminalCursorDefault
    private let backoffDelay: BackoffDelay
    private let onGridSent: GridSent?
    private let streamFocus: TerminalStreamFocus?

    /// Told each grid this view sends to the PTY and whether the daemon will echo it (a grid other than
    /// the one the stream last announced, or one sent while an earlier echo is still due).
    public typealias GridSent = @Sendable (_ size: CellSize, _ expectsEcho: Bool) -> Void

    /// Waits before a re-attach that follows `failedReconnects` failed ones
    /// in a row (the App passes a capped ``Backoff``). Throws when cancelled.
    public typealias BackoffDelay = @Sendable (_ failedReconnects: Int) async throws -> Void

    /// `restoring`: the view attaches to a terminal that already runs
    /// (``TerminalAttachMachine/init(initialSize:visible:restoring:)``).
    /// `onGridSent`: told each grid this view sends to the PTY (a claim or a take over of the live link),
    /// in reduction order under the reducer's lock, as the effect is queued (the applier sends it right
    /// after, in order); never a resize the machine dropped (no live link, hidden, or the grid it already
    /// holds). Must not block (the burst bench's trace).
    public init(
        initialSize: CellSize,
        visible: Bool = true,
        restoring: Bool = false,
        outputHighWater: Int = 1 << 20,
        opener: @escaping Opener,
        onFailure: @escaping @Sendable (any Error) -> Void = { _ in },
        onReattach: @escaping @Sendable (_ attempt: Int) -> Void = { _ in },
        observer: Observer? = nil,
        cursorDefault: TerminalCursorDefault = .ghostty,
        backoffDelay: @escaping BackoffDelay = { _ in },
        onGridSent: GridSent? = nil,
        // nil: the links' streams keep the priority they opened with (feature `terminalStreamPriority` off).
        streamFocus: TerminalStreamFocus? = nil
    ) {
        core = Mutex(Core(machine: Machine(initialSize: initialSize, visible: visible, restoring: restoring),
                          streamPriority: TerminalStreamPriority(visible: visible, focused: false),
                          ranksStreams: streamFocus != nil))
        queue = TerminalStepQueue(highWater: outputHighWater)
        self.opener = opener
        self.onFailure = onFailure
        self.onReattach = onReattach
        self.observer = observer
        self.cursorDefault = cursorDefault
        self.backoffDelay = backoffDelay
        self.onGridSent = onGridSent
        self.streamFocus = streamFocus
    }

    deinit {
        streamFocus?.release(ObjectIdentifier(self))
        // Nothing can reach this driver any more: free whatever it holds.
        let effects = core.withLock { core -> [Outgoing] in
            let effects = core.outbox + core.machine.reduce(.close).map { Outgoing(effect: $0) }
            core.outbox = []
            return effects
        }
        effects.forEach(apply)
    }

    // MARK: Consumer

    /// Next step for the view, or nil once the attachment ended for good.
    public func nextStep() async -> TerminalStreamPlan.Step? { await queue.next() }

    /// The view stopped consuming.
    public func cancelSteps() { queue.cancel() }

    /// Any thread: live output of every link this driver pumps, and of each it opens later, goes from the
    /// link's reader straight to `sink` (the view's output lane), in order with ``nextStep()``: the view
    /// resumes each ``TerminalStreamPlan/Step/outputResume(_:)`` once it applied the steps before it. Nil keeps
    /// output on the steps. Set under the reducer's lock, so a link opening meanwhile never keeps an older sink.
    public func setOutputSink(_ sink: TerminalEchoSink?) {
        core.withLock { core in
            core.sink = sink
            core.pumped.values.forEach { $0.link.setOutputSink(sink) }
        }
    }

    // MARK: Events

    public func start() { send(.start) }
    /// Input from the surface; `keyFlow` is the latency slot flow of the key press the bytes encode (0: none). The
    /// live link sends it with them; input held while attaching goes without it.
    public func input(_ data: Data, keyFlow: UInt64 = 0) { send(.input(data), keyFlow: keyFlow) }
    public func resize(_ size: CellSize) { send(.resize(size)) }
    public func setVisible(_ visible: Bool) {
        send(.visibility(visible))
        syncStreamPriority()
    }
    /// The surface gained keyboard focus (geometry and reconnect, in the view's input order).
    public func focused() { send(.focused) }
    /// The surface gained keyboard focus, in the order focus moves between views (the main thread's): its
    /// stream rides the input lane while it shows, until another view takes ``streamFocus``.
    public func takeStreamFocus() {
        guard let streamFocus else { return }
        streamFocus.take(ObjectIdentifier(self)) { [weak self] in self?.syncStreamPriority() }
        syncStreamPriority()
    }
    /// Take over from the "Sized for" chip.
    public func takeOver(setLatest: Bool) { send(.takeOver(setLatest: setLatest)) }
    /// The terminal or the daemon connection is back: a disconnected view
    /// re-attaches.
    public func reconnect() { send(.reconnect) }
    /// The daemon reports the terminal's process ended.
    public func processExited() { send(.processExited) }
    /// The daemon reports the terminal running again after a dead report.
    public func processRevived() { send(.processRevived) }
    public func close() { send(.close) }
    /// The view's local history did not match the host's: ask the live link
    /// for READY + history (`snapshot-request`, reason gap). Not a machine
    /// event: the link and its geometry stay as they are.
    public func requestResync() {
        core.withLock { $0.machine.liveLink }?.link.sendSnapshotRequest(reason: .gap)
    }

    /// Sends the priority the view's visibility and focus give to every pumped link, when it changed. Under the
    /// reducer's lock, as ``setOutputSink(_:)``: a link opening meanwhile reads the new one. Focus is read from
    /// ``streamFocus`` under that lock (the focus holder's lock nests inside and never calls out), so the last
    /// sync of a view sends what the holder is then: a take syncs the view it demotes after the change, and
    /// the view that took it after its take.
    private func syncStreamPriority() {
        guard let streamFocus else { return }
        let me = ObjectIdentifier(self)
        core.withLock { core in
            let priority = TerminalStreamPriority(visible: core.machine.visible, focused: streamFocus.holderView == me)
            guard core.streamPriority != priority else { return }
            core.streamPriority = priority
            core.pumped.values.forEach { $0.link.sendStreamPriority(priority) }
        }
    }

    /// The view's stream priority now (tests, diagnostics).
    public var streamPriority: TerminalStreamPriority { core.withLock { $0.streamPriority } }

    // MARK: Diagnostics

    public var machine: Machine { core.withLock { $0.machine } }
    public var bufferedOutputBytes: Int { queue.bufferedOutputBytes }

    // MARK: Reducer and applier

    /// Reduces `event` and applies what it makes; the input's own send carries `keyFlow`.
    private func send(_ event: Machine.Event, keyFlow: UInt64 = 0) {
        var batch = core.withLock { core -> [Outgoing] in
            let effects = core.machine.reduce(event)
            if let onGridSent { Self.reportGrids(effects, of: core.machine, to: onGridSent) }
            // A live link's input makes one send, its own; held input (sent after a replay) makes none.
            for effect in effects {
                let isInputsSend = if case .send = effect { true } else { false }
                core.outbox.append(Outgoing(effect: effect, keyFlow: isInputsSend ? keyFlow : 0))
            }
            observer?(event, core.machine)
            guard !core.applying, !core.outbox.isEmpty else { return [] }
            core.applying = true
            defer { core.outbox = [] }
            return core.outbox
        }
        while !batch.isEmpty {
            batch.forEach(apply)
            batch = core.withLock { core -> [Outgoing] in
                guard !core.outbox.isEmpty else {
                    core.applying = false
                    return []
                }
                defer { core.outbox = [] }
                return core.outbox
            }
        }
    }

    private func apply(_ outgoing: Outgoing) {
        switch outgoing.effect {
        case .open(let attempt, let size):
            if attempt > 1 { onReattach(attempt) }
            startAttempt(attempt, size: size, delay: nil)
        case .openAfterBackoff(let attempt, let size, let failedReconnects):
            onReattach(attempt)
            startAttempt(attempt, size: size, delay: failedReconnects)
        case .send(let ref, let data): ref.link.sendInput(data, keyFlow: outgoing.keyFlow)
        case .claim(let ref, let size): ref.link.sendClaim(reporting: size)
        case .takeOver(let ref, let size, let setLatest): ref.link.sendTakeOver(reporting: size, setLatest: setLatest)
        case .hide(let ref): ref.link.sendHidden(true)
        case .unhide(let ref): ref.link.sendHidden(false)
        case .detach(let ref): ref.link.detachNow()
        case .status(let status): queue.pushControl(.status(status))
        case .finish:
            queue.finish()
            // A re-attach still waiting out its backoff must not open.
            let tasks = core.withLock { core in core.tasks.values }
            tasks.forEach { $0.cancel() }
        }
    }

    /// Reports the grids `effects` send (``GridSent``). A claim adds its grid to the machine's due echoes
    /// exactly when the daemon will echo it, so the last due echo names it then.
    private static func reportGrids(_ effects: [Machine.Effect], of machine: Machine, to report: GridSent) {
        for effect in effects {
            switch effect {
            case .claim(_, let size), .takeOver(_, let size, _): report(size, machine.echoesDue.last == size)
            default: continue
            }
        }
    }

    private func startAttempt(_ attempt: Int, size: CellSize, delay failedReconnects: Int?) {
        core.withLock { core in
            core.tasks[attempt] = Task.detached(priority: .userInitiated) {
                [owner = Owner(self), opener, backoffDelay, cursorDefault] in
                if let failedReconnects {
                    do {
                        try await backoffDelay(failedReconnects)
                    } catch {
                        owner.value?.finishTask(attempt)
                        return
                    }
                }
                await Self.run(owner: owner, opener: opener, attempt: attempt, size: size, cursorDefault: cursorDefault)
            }
        }
    }

    // MARK: Attempt task

    /// Opens one link, reports it, and pumps its stream until it ends. Holds
    /// the driver only weakly while waiting, so a dropped view frees its link.
    private static func run(owner: Owner, opener: Opener, attempt: Int, size: CellSize,
                            cursorDefault: TerminalCursorDefault) async {
        guard let ref = await open(owner: owner, opener: opener, attempt: attempt, size: size) else { return }
        owner.value?.core.withLock { core in
            core.pumped[attempt] = ref
            ref.link.setOutputSink(core.sink)
            if core.ranksStreams { ref.link.sendStreamPriority(core.streamPriority) }
        }
        var ended: TerminalChannelCloseReason = .connectionLost("attach stream ended")
        stream: for await event in ref.link.events {
            guard let queue = owner.value?.queue else { break stream }
            for step in TerminalStreamPlan.steps(for: event, cursorDefault: cursorDefault) {
                // A grid change reaches the machine before the view applies it, so the view
                // reads the geometry claim that grid leaves (`TerminalIO.appliesViewGrid`).
                switch step {
                case .grid(let columns, let rows): owner.value?.send(.gridAnnounced(ref, CellSize(cols: columns, rows: rows)))
                // A local-history READY is also the grid change (no .grid step).
                case .snapshot(let frame) where frame.phase == .ready && frame.localHistory != nil:
                    if let cols = frame.cols, let rows = frame.rows {
                        owner.value?.send(.gridAnnounced(ref, CellSize(cols: cols, rows: rows)))
                    }
                default: break
                }
                await queue.push(step)
                switch step {
                case .replay: owner.value?.send(.replayDelivered(ref))
                // A link's first READY is its replay; later ones are no-ops there.
                case .snapshot(let frame) where frame.phase == .ready: owner.value?.send(.replayDelivered(ref))
                case .grid, .output, .inputEcho, .outputResume, .snapshot, .exited, .status, .sizing: break
                }
            }
            if case .closed(let reason) = event {
                ended = reason
                break stream
            }
        }
        guard let driver = owner.value else {
            ref.link.detachNow()
            return
        }
        driver.send(.ended(ref, ended))
        driver.finishTask(attempt)
    }

    /// The accepted link, or nil when the open failed or the machine moved
    /// on (the reducer then detached it).
    private static func open(owner: Owner, opener: Opener, attempt: Int, size: CellSize) async -> LinkRef? {
        let link: Link
        do {
            link = try await opener(size)
        } catch {
            guard let driver = owner.value else { return nil }
            if !(error is CancellationError) { driver.onFailure(error) }
            driver.send(.openFailed(attempt: attempt))
            driver.finishTask(attempt)
            return nil
        }
        let ref = LinkRef(link: link)
        guard let driver = owner.value else {
            link.detachNow()
            return nil
        }
        driver.send(.opened(ref, attempt: attempt))
        let accepted = driver.core.withLock { core -> Bool in
            switch core.machine.phase {
            case .attaching(let pending), .reattaching(let pending): pending.link == ref
            default: false
            }
        }
        if !accepted { driver.finishTask(attempt) }
        return accepted ? ref : nil
    }

    /// Weak reference to the driver that attempt tasks hold.
    private struct Owner: Sendable {
        weak var value: TerminalAttachDriver?
        init(_ value: TerminalAttachDriver) { self.value = value }
    }

    private func finishTask(_ attempt: Int) {
        core.withLock { core in
            core.tasks.removeValue(forKey: attempt)
            core.pumped.removeValue(forKey: attempt)
        }
    }
}

/// The live link: a daemon byte-mode attachment on its own connection.
extension TerminalAttachment: TerminalAttachLink {
    public nonisolated func sendInput(_ data: Data, keyFlow: UInt64) { enqueueInput(data, keyFlow: keyFlow) }
    public nonisolated func sendClaim(reporting size: CellSize) { claimGeometry(reporting: size) }
    public nonisolated func sendTakeOver(reporting size: CellSize, setLatest: Bool) { takeOver(reporting: size, setLatest: setLatest) }
    public nonisolated func sendSnapshotRequest(reason: SnapshotRequestReason) { requestSnapshot(reason: reason) }
    public nonisolated func sendStreamPriority(_ priority: TerminalStreamPriority) { setStreamPriority(priority) }
}

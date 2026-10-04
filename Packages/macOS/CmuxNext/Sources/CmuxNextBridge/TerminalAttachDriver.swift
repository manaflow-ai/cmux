public import CmuxNextDaemon
public import Foundation
import Synchronization

/// One open daemon attachment as the driver uses it. Every command is a
/// synchronous, nonblocking send, so the driver applies effects in order
/// without hopping between tasks (state-audit.md T4).
public nonisolated protocol TerminalAttachLink: AnyObject, Sendable {
    /// `replay -> (output | resized | …)* -> closed`, finishing after `closed`.
    var events: AsyncStream<TerminalChannelEvent> { get }
    func sendInput(_ data: Data)
    /// Reports `size`, then claims canonical geometry.
    func sendClaim(reporting size: CellSize)
    func sendReleaseGeometry()
    /// Detaches and closes the connection; its `events` then finish.
    /// Idempotent.
    func detachNow()
}

/// Runs a ``TerminalAttachMachine`` against real attachments: one reducer
/// under one lock, one effect applier, and one pump per open link feeding a
/// bounded ``TerminalStepQueue``.
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

    private struct Core {
        var machine: Machine
        var outbox: [Machine.Effect] = []
        var applying = false
        /// One task per attach attempt: opens the link, then pumps it.
        var tasks: [Int: Task<Void, Never>] = [:]
    }

    private let core: Mutex<Core>
    private let queue: TerminalStepQueue
    private let opener: Opener
    private let onFailure: @Sendable (any Error) -> Void
    private let onReattach: @Sendable (Int) -> Void
    private let observer: Observer?
    private let cursorDefault: TerminalCursorDefault
    private let backoffDelay: BackoffDelay

    /// Waits before a re-attach that follows `failedReconnects` failed ones
    /// in a row (the App passes a capped ``Backoff``). Throws when cancelled.
    public typealias BackoffDelay = @Sendable (_ failedReconnects: Int) async throws -> Void

    public init(
        initialSize: CellSize,
        visible: Bool = true,
        outputHighWater: Int = 1 << 20,
        opener: @escaping Opener,
        onFailure: @escaping @Sendable (any Error) -> Void = { _ in },
        onReattach: @escaping @Sendable (_ attempt: Int) -> Void = { _ in },
        observer: Observer? = nil,
        cursorDefault: TerminalCursorDefault = .ghostty,
        backoffDelay: @escaping BackoffDelay = { _ in }
    ) {
        core = Mutex(Core(machine: Machine(initialSize: initialSize, visible: visible)))
        queue = TerminalStepQueue(highWater: outputHighWater)
        self.opener = opener
        self.onFailure = onFailure
        self.onReattach = onReattach
        self.observer = observer
        self.cursorDefault = cursorDefault
        self.backoffDelay = backoffDelay
    }

    deinit {
        // Nothing can reach this driver any more: free whatever it holds.
        let effects = core.withLock { core -> [Machine.Effect] in
            let effects = core.outbox + core.machine.reduce(.close)
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

    // MARK: Events

    public func start() { send(.start) }
    public func input(_ data: Data) { send(.input(data)) }
    public func resize(_ size: CellSize) { send(.resize(size)) }
    public func setVisible(_ visible: Bool) { send(.visibility(visible)) }
    /// The surface gained keyboard focus.
    public func focused() { send(.focused) }
    /// The terminal or the daemon connection is back: a disconnected view
    /// re-attaches.
    public func reconnect() { send(.reconnect) }
    /// The daemon reports the terminal's process ended.
    public func processExited() { send(.processExited) }
    /// The daemon reports the terminal running again after a dead report.
    public func processRevived() { send(.processRevived) }
    public func close() { send(.close) }

    // MARK: Diagnostics

    public var machine: Machine { core.withLock { $0.machine } }
    /// Attach attempts whose task is still running (open or pump).
    public var runningTasks: Int { core.withLock { $0.tasks.count } }
    public var bufferedOutputBytes: Int { queue.bufferedOutputBytes }

    // MARK: Reducer and applier

    private func send(_ event: Machine.Event) {
        var batch = core.withLock { core -> [Machine.Effect] in
            core.outbox += core.machine.reduce(event)
            observer?(event, core.machine)
            guard !core.applying, !core.outbox.isEmpty else { return [] }
            core.applying = true
            defer { core.outbox = [] }
            return core.outbox
        }
        while !batch.isEmpty {
            batch.forEach(apply)
            batch = core.withLock { core -> [Machine.Effect] in
                guard !core.outbox.isEmpty else {
                    core.applying = false
                    return []
                }
                defer { core.outbox = [] }
                return core.outbox
            }
        }
    }

    private func apply(_ effect: Machine.Effect) {
        switch effect {
        case .open(let attempt, let size):
            if attempt > 1 { onReattach(attempt) }
            startAttempt(attempt, size: size, delay: nil)
        case .openAfterBackoff(let attempt, let size, let failedReconnects):
            onReattach(attempt)
            startAttempt(attempt, size: size, delay: failedReconnects)
        case .send(let ref, let data): ref.link.sendInput(data)
        case .claim(let ref, let size): ref.link.sendClaim(reporting: size)
        case .release(let ref): ref.link.sendReleaseGeometry()
        case .detach(let ref): ref.link.detachNow()
        case .status(let status): queue.pushControl(.status(status))
        case .finish:
            queue.finish()
            // A re-attach still waiting out its backoff must not open.
            let tasks = core.withLock { core in core.tasks.values }
            tasks.forEach { $0.cancel() }
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
        var ended: TerminalChannelCloseReason = .connectionLost("attach stream ended")
        stream: for await event in ref.link.events {
            guard let queue = owner.value?.queue else { break stream }
            for step in TerminalStreamPlan.steps(for: event, cursorDefault: cursorDefault) {
                await queue.push(step)
                switch step {
                case .replay: owner.value?.send(.replayDelivered(ref))
                // A link's first READY is its replay; later ones are no-ops there.
                case .snapshot(let frame) where frame.phase == .ready: owner.value?.send(.replayDelivered(ref))
                case .grid(let columns, let rows): owner.value?.send(.gridAnnounced(ref, CellSize(cols: columns, rows: rows)))
                case .output, .snapshot, .exited, .status: break
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
    private struct Owner: @unchecked Sendable {
        // Written once at init; the referent is Sendable.
        weak var value: TerminalAttachDriver?
        init(_ value: TerminalAttachDriver) { self.value = value }
    }

    private func finishTask(_ attempt: Int) {
        _ = core.withLock { $0.tasks.removeValue(forKey: attempt) }
    }
}

/// The live link: a daemon byte-mode attachment on its own connection.
extension TerminalAttachment: TerminalAttachLink {
    public nonisolated func sendInput(_ data: Data) { enqueueInput(data) }
    public nonisolated func sendClaim(reporting size: CellSize) { claimGeometry(reporting: size) }
}

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
    /// Passive grid report.
    func sendResize(_ size: CellSize)
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

    public init(
        initialSize: CellSize,
        visible: Bool = true,
        outputHighWater: Int = 1 << 20,
        opener: @escaping Opener,
        onFailure: @escaping @Sendable (any Error) -> Void = { _ in }
    ) {
        core = Mutex(Core(machine: Machine(initialSize: initialSize, visible: visible)))
        queue = TerminalStepQueue(highWater: outputHighWater)
        self.opener = opener
        self.onFailure = onFailure
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
            core.withLock { core in
                core.tasks[attempt] = Task.detached(priority: .userInitiated) { [owner = Owner(self), opener] in
                    await Self.run(owner: owner, opener: opener, attempt: attempt, size: size)
                }
            }
        case .cancelOpen(let attempt):
            core.withLock { $0.tasks[attempt] }?.cancel()
        case .send(let ref, let data): ref.link.sendInput(data)
        case .resize(let ref, let size): ref.link.sendResize(size)
        case .claim(let ref, let size): ref.link.sendClaim(reporting: size)
        case .release(let ref): ref.link.sendReleaseGeometry()
        case .detach(let ref): ref.link.detachNow()
        case .finish: queue.finish()
        }
    }

    // MARK: Attempt task

    /// Opens one link, reports it, and pumps its stream until it ends. Holds
    /// the driver only weakly while waiting, so a dropped view frees its link.
    private static func run(owner: Owner, opener: Opener, attempt: Int, size: CellSize) async {
        guard let ref = await open(owner: owner, opener: opener, attempt: attempt, size: size) else { return }
        var ended: TerminalChannelCloseReason = .connectionLost("attach stream ended")
        stream: for await event in ref.link.events {
            guard let queue = owner.value?.queue else { break stream }
            for step in TerminalStreamPlan.steps(for: event) {
                await queue.push(step)
                if case .replay = step { owner.value?.send(.replayDelivered(ref)) }
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

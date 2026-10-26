public import CmuxNextWakeups

/// Keyed waits on one page (plans/cmux-next/chrome-parity/p06-scheduler.md, section C, task 028):
/// ``BrowserTab/when(phase:deadline:)`` and ``BrowserTab/whenPrompt(kind:deadline:)``.
///
/// A predicate wait (an `ObservationStream` over `state` or `pendingPrompts`) reads its condition
/// again on every change of the page's state, a title tick or a progress tick too. Here the page's
/// own setters tell the waiters what changed: a load-phase change reads the phase waiters, a new
/// prompt reads the prompt waiters, and nothing else reads any. Chromium signals its waiters from
/// the change itself the same way, never from a poll (`WebContentsObserver::DidFinishLoad` and
/// `JavaScriptDialogManager::RunBeforeUnloadDialog` call their observers;
/// content/public/browser/web_contents_observer.h).
///
/// A wait resumes exactly once: with its value when the condition holds, or with nil when its
/// deadline passes (``Deadline``, an entry on the main thread's one deadline queue), when the
/// waiting task is cancelled, or when the page ends (``pageEnded()``).
@MainActor public final class PageWaiters {
    /// What a wait is filed under: the setter whose change can satisfy it.
    nonisolated enum Slot: Hashable, Sendable {
        case phase
        case prompt
    }

    /// The page's change a slot's waiters read.
    enum Change {
        case phase(BrowserLoadPhase)
        case prompts([BrowserPrompt])
    }

    /// How long a wait may last: its timeout, an entry on the main thread's one deadline queue
    /// (``AlignedWakeups`` over `MainWakeUpQueue`), so pending waits share its wakes and no wait
    /// has a timer of its own.
    public nonisolated struct Deadline: Sendable {
        let timeout: Duration
        let queue: AlignedWakeups

        /// - Parameters:
        ///   - timeout: How long the wait lasts at most.
        ///   - queue: The main thread's deadline queue.
        public init(after timeout: Duration, on queue: AlignedWakeups) {
            self.timeout = timeout
            self.queue = queue
        }
    }

    /// One waiter: resumed exactly once, by `resumeIfReady` or `abandon`, after which it is
    /// dropped and its timeout cancelled.
    private struct Waiter {
        /// Resumes with the condition's value when the change satisfies it; whether it did.
        let resumeIfReady: @MainActor (Change) -> Bool
        /// Resumes with nil (deadline, cancel, page ended).
        let abandon: @MainActor () -> Void
        let timeout: (queue: AlignedWakeups, ticket: AlignedWakeups.Ticket)?
    }

    /// The `WakeupLedger` owner of the waits' deadlines.
    public static let deadlineOwner = "BrowserTab.waiters"

    private var waiting: [Slot: [UInt64: Waiter]] = [:]
    private var nextSerial: UInt64 = 0
    private var hasEnded = false
    /// ``untilPending(_:)`` calls waiting for a count.
    private var pendingWatchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    /// Waiter conditions read since creation, at registration and on a change (tests: a title
    /// change reads none).
    public private(set) var evaluations = 0
    /// Waits still waiting.
    public private(set) var pendingCount = 0

    /// No waits.
    public init() {}

    // MARK: Setter hooks

    /// The page's load phase changed to `phase`. Its setter calls this only on a change of phase.
    public func notePhase(_ phase: BrowserLoadPhase) {
        settle(.phase, .phase(phase))
    }

    /// The page's prompts are now `prompts`, one or more of them new. Its setter calls this only
    /// when a prompt was added: a removed prompt satisfies no wait.
    public func notePromptsAdded(_ prompts: [BrowserPrompt]) {
        settle(.prompt, .prompts(prompts))
    }

    /// The page closed: every wait resumes with nil, and later waits return nil at once.
    public func pageEnded() {
        hasEnded = true
        let pending = waiting.flatMap { entry in entry.value.keys.map { (slot: entry.key, serial: $0) } }
        for entry in pending.sorted(by: { $0.serial < $1.serial }) { abandon(entry.slot, entry.serial) }
    }

    private func settle(_ slot: Slot, _ change: Change) {
        guard let waiters = waiting[slot] else { return }
        for (serial, waiter) in waiters.sorted(by: { $0.key < $1.key }) {
            evaluations += 1
            if waiter.resumeIfReady(change) { take(slot, serial) }
        }
    }

    // MARK: Waiting

    /// Returns `read(now)` once it is non-nil, read now and then only on `slot`'s changes; nil when
    /// `deadline` passes, the calling task is cancelled or the page ends.
    func value<Value: Sendable>(of slot: Slot, now: Change, deadline: Deadline?,
                                read: @escaping @MainActor (Change) -> Value?) async -> Value? {
        evaluations += 1
        if let value = read(now) { return value }
        guard !hasEnded, !Task.isCancelled else { return nil }
        nextSerial &+= 1
        let serial = nextSerial
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                // Cancelled between the check above and here: the handler's hop finds nothing to drop.
                guard !Task.isCancelled else { return continuation.resume(returning: nil) }
                // Strong: the queue keeps the waiters until the deadline resumes this wait, whoever drops the page.
                let timeout = deadline.map { deadline in
                    (queue: deadline.queue,
                     ticket: deadline.queue.schedule(owner: Self.deadlineOwner, after: deadline.timeout) { self.abandon(slot, serial) })
                }
                let waiter = Waiter(
                    resumeIfReady: { change in
                        guard let value = read(change) else { return false }
                        continuation.resume(returning: value)
                        return true
                    },
                    abandon: { continuation.resume(returning: nil) },
                    timeout: timeout
                )
                waiting[slot, default: [:]][serial] = waiter
                pendingCount += 1
                resumePendingWatchers()
            }
        } onCancel: {
            // task-owner: one hop to the main actor that owns the waiters; a waiter already resumed is not found.
            Task { @MainActor in self.abandon(slot, serial) }
        }
    }

    /// Returns once at least `count` waits are waiting (tests: a wait started in a task has filed itself).
    func untilPending(_ count: Int) async {
        guard pendingCount < count else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingWatchers.append((count, continuation))
        }
    }

    private func resumePendingWatchers() {
        guard !pendingWatchers.isEmpty else { return }
        let ready = pendingWatchers.filter { $0.count <= pendingCount }
        pendingWatchers.removeAll { $0.count <= pendingCount }
        for watcher in ready { watcher.continuation.resume() }
    }

    private func abandon(_ slot: Slot, _ serial: UInt64) {
        take(slot, serial)?.abandon()
    }

    /// Drops the waiter and its pending deadline; nil when it already resumed.
    @discardableResult
    private func take(_ slot: Slot, _ serial: UInt64) -> Waiter? {
        guard let waiter = waiting[slot]?.removeValue(forKey: serial) else { return nil }
        pendingCount -= 1
        if waiting[slot]?.isEmpty == true { waiting[slot] = nil }
        if let timeout = waiter.timeout { timeout.queue.cancel(timeout.ticket) }
        return waiter
    }
}

/// A page whose setters resume its keyed waits (``PageWaiters``). A page that is not one reports
/// no phase or prompt change: its waits read the condition once.
@MainActor public protocol BrowserPageWaiting: AnyObject {
    /// The page's waits; its load-phase and prompt setters call the hooks.
    var pageWaiters: PageWaiters { get }
}

extension BrowserTab {
    // MARK: Keyed page waits (PageWaiters)

    /// The page's load phase once `matches` holds for it, read now and then only when the phase
    /// changes (never on a title or progress change); nil when `deadline` passes, the task is
    /// cancelled or the page ends.
    public func when(phase matches: @escaping @MainActor (BrowserLoadPhase) -> Bool,
                     deadline: PageWaiters.Deadline? = nil) async -> BrowserLoadPhase? {
        let read: @MainActor (PageWaiters.Change) -> BrowserLoadPhase? = { change in
            guard case .phase(let phase) = change else { return nil }
            return matches(phase) ? phase : nil
        }
        guard let waiters = (self as? any BrowserPageWaiting)?.pageWaiters else { return read(.phase(state.phase)) }
        return await waiters.value(of: .phase, now: .phase(state.phase), deadline: deadline, read: read)
    }

    /// True once the page's load phase is `phase`; false when `deadline` passes, the task is
    /// cancelled or the page ends.
    public func when(phase: BrowserLoadPhase, deadline: PageWaiters.Deadline? = nil) async -> Bool {
        await when(phase: { $0 == phase }, deadline: deadline) != nil
    }

    /// The page's first unanswered prompt whose kind `matches`, read now and then only when the
    /// page adds a prompt; nil when `deadline` passes, the task is cancelled or the page ends.
    public func whenPrompt(kind matches: @escaping @MainActor (BrowserPromptKind) -> Bool,
                           deadline: PageWaiters.Deadline? = nil) async -> BrowserPrompt? {
        let read: @MainActor (PageWaiters.Change) -> BrowserPrompt? = { change in
            guard case .prompts(let prompts) = change else { return nil }
            return prompts.first { !$0.isResolved && matches($0.kind) }
        }
        guard let waiters = (self as? any BrowserPageWaiting)?.pageWaiters else { return read(.prompts(pendingPrompts)) }
        return await waiters.value(of: .prompt, now: .prompts(pendingPrompts), deadline: deadline, read: read)
    }
}

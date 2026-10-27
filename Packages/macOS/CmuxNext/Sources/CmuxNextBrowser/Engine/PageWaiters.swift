import CmuxNextWakeups

/// Keyed waits on one page (plans/cmux-next/chrome-parity/p06-scheduler.md, section C, task 028):
/// ``BrowserPageWaiting/when(phase:timeout:)`` and ``BrowserPageWaiting/whenPrompt(kind:timeout:)``.
///
/// A predicate wait (an `ObservationStream` over `state` or `pendingPrompts`) reads its condition
/// again on every change of the page's state, a title tick or a progress tick too. Here the page's
/// own setters tell the waiters what changed: a load-phase change reads the phase waiters, a new
/// prompt reads the prompt waiters, and nothing else reads any. Chromium tells its observers from
/// the change itself the same way: `WebContentsObserver::DidStartLoading` / `DidStopLoading`
/// (content/public/browser/web_contents_observer.h) for the load, and the page's dialog reaches the
/// browser as a `JavaScriptDialogManager::RunJavaScriptDialog` / `RunBeforeUnloadDialog` call
/// (content/public/browser/javascript_dialog_manager.h).
///
/// The waits are a ``KeyedWaiters`` (CmuxNextWakeups), the engine the store's waits share: each
/// resumes exactly once, with its value on the transition, or with nil when its timeout passes, its
/// task is cancelled or the page ends (``pageEnded()``).
@MainActor final class PageWaiters {
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

    /// The `WakeupLedger` owner of the waits' timeouts.
    static let deadlineOwner = "BrowserTab.waiters"

    private let keyed: KeyedWaiters<Slot, Change>
    /// Waiter conditions read since creation, at registration and on a change (tests: a title
    /// change reads none).
    var evaluations: Int { keyed.evaluations }
    /// Waits still waiting.
    var pendingCount: Int { keyed.pendingCount }

    /// - Parameter deadlines: Where the waits' timeouts go: the main thread's one deadline queue,
    ///   handed to the page by its engine.
    init(deadlines: AlignedWakeups) {
        keyed = KeyedWaiters(deadlines: deadlines, deadlineOwner: Self.deadlineOwner)
    }

    // MARK: Setter hooks

    /// The page's load phase changed to `phase`. Its setter calls this only on a change of phase.
    func notePhase(_ phase: BrowserLoadPhase) {
        keyed.settle(.phase, with: .phase(phase))
    }

    /// The page's prompts are now `prompts`, one or more of them new. Its setter calls this only
    /// when a prompt was added: a removed prompt satisfies no wait.
    func notePromptsAdded(_ prompts: [BrowserPrompt]) {
        keyed.settle(.prompt, with: .prompts(prompts))
    }

    /// The page closed: every wait resumes with nil, and later waits return nil at once.
    func pageEnded() {
        keyed.end()
    }

    // MARK: Waiting

    /// The load phase once `matches` holds for it, read now (`current`) and then only on a phase
    /// change; nil after `timeout`, on cancel or once the page ended.
    func phase(where matches: @escaping @MainActor (BrowserLoadPhase) -> Bool, current: BrowserLoadPhase,
               timeout: Duration) async -> BrowserLoadPhase? {
        await keyed.value(of: .phase, now: .phase(current), timeout: timeout) { (change: Change) -> BrowserLoadPhase? in
            guard case .phase(let phase) = change else { return nil }
            return matches(phase) ? phase : nil
        }
    }

    /// The first unanswered prompt whose kind `matches`, read now (`current`) and then only when the
    /// page adds a prompt; nil after `timeout`, on cancel or once the page ended.
    func prompt(where matches: @escaping @MainActor (BrowserPromptKind) -> Bool, current: [BrowserPrompt],
                timeout: Duration) async -> BrowserPrompt? {
        await keyed.value(of: .prompt, now: .prompts(current), timeout: timeout) { (change: Change) -> BrowserPrompt? in
            guard case .prompts(let prompts) = change else { return nil }
            return prompts.first { !$0.isResolved && matches($0.kind) }
        }
    }

    /// Returns once at least `count` waits are waiting (tests: a wait started in a task has filed itself).
    func untilPending(_ count: Int) async {
        await keyed.untilPending(count)
    }
}

/// A page whose load-phase and prompt setters resume keyed waits (``PageWaiters``): only such a
/// page offers them, so no caller can wait on a page that would never wake the wait.
public protocol BrowserPageWaiting: BrowserTab {
    /// The page's load phase once `matches` holds for it, read now and then only when the phase
    /// changes (never on a title or progress change); nil after `timeout`, when the task is
    /// cancelled or when the page closes.
    func when(phase matches: @escaping @MainActor (BrowserLoadPhase) -> Bool, timeout: Duration) async -> BrowserLoadPhase?

    /// The page's first unanswered prompt whose kind `matches`, read now and then only when the
    /// page adds a prompt; nil after `timeout`, when the task is cancelled or when the page closes.
    func whenPrompt(kind matches: @escaping @MainActor (BrowserPromptKind) -> Bool, timeout: Duration) async -> BrowserPrompt?
}

extension BrowserPageWaiting {
    /// True once the page's load phase is `phase`; false after `timeout`, when the task is
    /// cancelled or when the page closes.
    public func when(phase: BrowserLoadPhase, timeout: Duration) async -> Bool {
        await when(phase: { $0 == phase }, timeout: timeout) != nil
    }
}

extension CEFTab: BrowserPageWaiting {
    public func when(phase matches: @escaping @MainActor (BrowserLoadPhase) -> Bool, timeout: Duration) async -> BrowserLoadPhase? {
        await pageWaiters.phase(where: matches, current: state.phase, timeout: timeout)
    }

    public func whenPrompt(kind matches: @escaping @MainActor (BrowserPromptKind) -> Bool, timeout: Duration) async -> BrowserPrompt? {
        await pageWaiters.prompt(where: matches, current: pendingPrompts, timeout: timeout)
    }
}

extension WebKitTab: BrowserPageWaiting {
    public func when(phase matches: @escaping @MainActor (BrowserLoadPhase) -> Bool, timeout: Duration) async -> BrowserLoadPhase? {
        await pageWaiters.phase(where: matches, current: state.phase, timeout: timeout)
    }

    public func whenPrompt(kind matches: @escaping @MainActor (BrowserPromptKind) -> Bool, timeout: Duration) async -> BrowserPrompt? {
        await pageWaiters.prompt(where: matches, current: pendingPrompts, timeout: timeout)
    }
}

extension MockBrowserTab: BrowserPageWaiting {
    public func when(phase matches: @escaping @MainActor (BrowserLoadPhase) -> Bool, timeout: Duration) async -> BrowserLoadPhase? {
        await pageWaiters.phase(where: matches, current: state.phase, timeout: timeout)
    }

    public func whenPrompt(kind matches: @escaping @MainActor (BrowserPromptKind) -> Bool, timeout: Duration) async -> BrowserPrompt? {
        await pageWaiters.prompt(where: matches, current: pendingPrompts, timeout: timeout)
    }
}

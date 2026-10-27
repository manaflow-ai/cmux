import CmuxNextCompat
public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// When a tab may start Chromium during launch, by its ``BrowserTabOrigin`` (p08-startup.md section 3D).
/// Chrome's session restore loads the visible tab first and leaves the others to its `TabLoader`
/// (chrome/browser/sessions/tab_loader.cc), and work for what does not show waits for startup complete
/// (`AfterStartupTaskUtils`, chrome/browser/after_startup_task_utils.cc):
///
/// - ``BrowserTabOrigin/user`` and ``BrowserTabOrigin/automation`` start at once (input first).
/// - ``BrowserTabOrigin/restoreVisible`` starts in an `afterFirstFrame` post: after the picture frame
///   and before completion, which the visible pane's ref holds open until the page loaded. It never
///   waits for completion, so the two never wait for each other.
/// - ``BrowserTabOrigin/restoreHidden`` starts in an `afterStartup` post. The App does not ask for one
///   before completion: it shows a restored page that does not show as its deferred page
///   (`TabContentCache.deferred`, ``DeferredBrowserTab``) and starts it by ``startHidden(when:_:)``.
///
/// The App's Chromium slot holds the one instance (``ChromiumEngineSlot/launchOrder``) the App reads
/// (``restoredOrigin(isShown:wasStarted:)``); the engine orders its own starts over the same scheduler.
///
/// It only orders: the posts go to the launch's one ``StartupScheduler``. With no scheduler (feature
/// `cefLaunchOrigin` off, tests) or after completion every origin starts at once.
///
/// ```swift
/// await deferral.waitForStart(of: configuration.origin)
/// try await startRuntime()
/// ```
public final class CEFLaunchDeferral {
    /// The launch's scheduler; nil starts every tab at once.
    let startup: StartupScheduler?

    /// - Parameter startup: The launch's scheduler; nil starts every tab at once.
    public init(startup: StartupScheduler?) {
        self.startup = startup
    }

    /// Returns once a tab of `origin` may start Chromium: at once, or when its launch post runs. A post
    /// the scheduler drops at quit returns too, so the start that follows fails as any start after quit does.
    public func waitForStart(of origin: BrowserTabOrigin) async {
        guard let startup, startup.completion == nil, let launchPost = Self.post(of: origin) else { return }
        // StartTurn answers a dropped post itself (no abandonment fault: a drop at quit is expected).
        try? await withOnceContinuation { (resume: OnceContinuation<Void, OnceContinuationError>) in
            let turn = StartTurn(resume)
            startup.post(launchPost.priority, launchPost.name, on: .main) { turn.take() }
        }
    }

    /// The origin of a restored page made now: `.restoreVisible` when it shows, else `.restoreHidden`, or
    /// `.automation` once something started it (a command's reload: made now, never deferred again). `.user`
    /// with no scheduler or after completion.
    public func restoredOrigin(isShown: Bool, wasStarted: Bool) -> BrowserTabOrigin {
        guard let startup, startup.completion == nil else { return .user }
        if isShown { return .restoreVisible }
        return wasStarted ? .automation : .restoreHidden
    }

    /// Runs `start` for a `.restoreHidden` page (shown as a deferred page meanwhile) at the first of: `node`
    /// shows, or startup completes (an afterStartup post). `start` may run twice and must start the page once.
    public func startHidden(when node: VisibilityNode, _ start: @escaping @MainActor @Sendable () -> Void) {
        guard let startup, startup.completion == nil else { return start() }
        node.deferUntilVisible(key: Self.hiddenStartKey, start)
        startup.post(.afterStartup, "Chromium.restoreHidden.start", on: .main, start)
    }

    /// The `deferUntilVisible` key of a hidden restored page's start.
    private static let hiddenStartKey = "CEFLaunchDeferral.hiddenStart"

    /// The launch post a tab of `origin` waits for, nil when it starts at once.
    nonisolated static func post(of origin: BrowserTabOrigin) -> (priority: StartupPriority, name: StaticString)? {
        switch origin {
        case .user, .automation: nil
        case .restoreVisible: (priority: .afterFirstFrame, name: "Chromium.start.restoreVisible")
        case .restoreHidden: (priority: .afterStartup, name: "Chromium.start.restoreHidden")
        }
    }
}

/// One wait for a launch post: answered by the post, or by its release when the scheduler drops it at quit.
private nonisolated final class StartTurn: Sendable {
    private let resume: OnceContinuation<Void, OnceContinuationError>
    private let answered = Atomic<Bool>(false)

    init(_ resume: OnceContinuation<Void, OnceContinuationError>) {
        self.resume = resume
    }

    func take() {
        guard !answered.exchange(true, ordering: .acquiringAndReleasing) else { return }
        resume.resume(returning: ())
    }

    deinit { take() }
}

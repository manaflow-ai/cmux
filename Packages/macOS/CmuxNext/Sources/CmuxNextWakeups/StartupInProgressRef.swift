/// One reason startup is not complete yet (Chrome's `StartupInProgressRef`,
/// chrome/browser/after_startup_task_utils.cc): ``StartupScheduler`` completes when every ref,
/// its two implicit ones included (registration and the first frame), is released, or when its
/// failsafe fires.
///
/// Release a ref exactly once, with the reason it ends; a second release does nothing. A ref that
/// is never released holds startup until the failsafe, which records the reason `failsafe`, so a
/// lost ref shows in the reason histogram instead of hiding. The scheduler keys each ref by an
/// ``id`` it never hands out twice, so a ref dropped unreleased stays held even after the
/// allocator gives its memory to a later ref.
///
/// ```swift
/// let restore = startup.hold("WindowManager.restore")
/// windows.restore { restore.release(.noVisiblePane) }
/// ```
@MainActor
public final class StartupInProgressRef {
    /// What the ref waits for (`debug.startup` lists the refs still held).
    public let name: StaticString
    /// The scheduler's key for this ref: unique per scheduler, never reused (0 for a ref that holds nothing).
    public let id: UInt64
    /// True once released (or made after completion or quit, when it holds nothing).
    public private(set) var isReleased: Bool
    private weak var scheduler: StartupScheduler?

    init(name: StaticString, id: UInt64, scheduler: StartupScheduler?) {
        self.name = name
        self.id = id
        self.scheduler = scheduler
        isReleased = scheduler == nil
    }

    /// Ends the hold. The reason becomes the completion reason when this is the last ref.
    ///
    /// - Parameter reason: Why the hold ends.
    public func release(_ reason: Reason) {
        guard !isReleased else { return }
        isReleased = true
        scheduler?.refReleased(self, reason: reason)
    }

    /// Why a hold ended; the last one is the startup completion reason
    /// (Chrome's `Startup.BrowserStartupCompleteReason`). Positions are fixed (the
    /// `launch.startup_complete` ring record stores position + 1): append a new reason, never insert.
    public nonisolated enum Reason: String, Sendable, CaseIterable, CustomStringConvertible {
        /// The app finished registering its launch work (``StartupScheduler/finishRegistration()``).
        case registrationFinished
        /// The first window's first frame was committed (``StartupScheduler/firstFrameCommitted()``).
        case firstFrameCommitted
        /// A visible pane reached loaded-idle.
        case visiblePaneLoadedIdle
        /// A visible pane did not reach loaded-idle within its bound.
        case visiblePaneTimedOut
        /// No pane is visible.
        case noVisiblePane
        /// The launch shows no window.
        case noWindow
        /// The daemon could not be reached, so no pane can load.
        case daemonUnavailable
        /// The failsafe deadline fired with refs still held.
        case failsafe
        /// The launch's ``StartupPhase`` settled by its references. No longer released: the settle's ref
        /// ends with the reason released before it (kept for its fixed position).
        case launchPhaseSettled
        /// The session restore ended with each visible pane holding its own ref (`VisiblePaneRefs`), so
        /// it is never the last release.
        case restoreFinished

        public var description: String { rawValue }
    }
}

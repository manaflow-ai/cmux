public import AppKit
public import CmuxNextWakeups

/// Ends closed pages after the close's turn (p13-webui-064): ``retire(_:close:)`` takes the view out of
/// the view tree at once, the only part a Cmd-W frame pays for, and runs its teardown (the engine page's
/// close, the bridge, the subscriptions) at one background deadline after the last close.
///
/// Chrome takes a closing tab out of the strip at once and ends its `WebContents` on later tasks: a tab
/// with unload work stays alive, detached and hidden, until `UnloadController::ProcessPendingTabs`
/// (chrome/browser/ui/unload_controller.cc) ends it, and owners free what a task still uses with
/// `base::SequencedTaskRunner::DeleteSoon` (base/task/sequenced_task_runner.h). ``WebUIHost/close(_:)``
/// retires every page here and the agent panes retire here too, so the app has one such deadline.
@MainActor
public final class PageRetirer {
    /// How long after the last retire the teardown waits: past the close's frame and the frames of a
    /// burst of closes (a held Cmd-W), which each push it back.
    public static let delay: Duration = .milliseconds(500)

    private struct Retiring {
        let view: NSView
        let close: @MainActor () -> Void
    }

    private var retiring: [Retiring] = []
    /// The teardown runs in the background class: nobody sees a closed page end.
    private let deadline: MainDeadline

    /// - Parameter deadlines: The app's one deadline scheduler (`AppServices.mainDeadlines`); a test passes
    ///   one on a fake wake-up timer and uptime, or calls ``closeRetired()``.
    public init(deadlines: MainDeadlineScheduler = MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()))) {
        deadline = MainDeadline(owner: "webui.retire", workClass: .background, scheduler: deadlines)
    }

    /// The views retired and not yet closed.
    public var count: Int { retiring.count }

    /// Whether `view` is retired and not yet closed (``reclaim(_:)`` can still take it back).
    public func isRetiring(_ view: NSView) -> Bool {
        retiring.contains { $0.view === view }
    }

    /// Takes `view` out of the view tree now and runs `close` at the teardown deadline. A view retired
    /// already keeps its first close: it runs once.
    ///
    /// - Parameters:
    ///   - view: The page that stops showing for good.
    ///   - close: Its teardown. It holds the view until it runs.
    public func retire(_ view: NSView, close: @escaping @MainActor () -> Void) {
        view.removeFromSuperview()
        guard !isRetiring(view) else { return }
        retiring.append(Retiring(view: view, close: close))
        // Strong: the pending deadline holds the retirer, so a retired page ends even when its host goes first.
        deadline.schedule(after: Self.delay) { [self] in closeRetired() }
    }

    /// Takes back `view` before its teardown ran: its close never runs.
    ///
    /// - Returns: False when `view` was not retired or is closed already.
    @discardableResult
    public func reclaim(_ view: NSView) -> Bool {
        guard let index = retiring.firstIndex(where: { $0.view === view }) else { return false }
        retiring.remove(at: index)
        if retiring.isEmpty { deadline.cancel() }
        return true
    }

    /// Runs the teardown of every retired view now, oldest first (the deadline's action; tests call it).
    public func closeRetired() {
        deadline.cancel()
        let due = retiring
        retiring.removeAll()
        for page in due { page.close() }
    }
}

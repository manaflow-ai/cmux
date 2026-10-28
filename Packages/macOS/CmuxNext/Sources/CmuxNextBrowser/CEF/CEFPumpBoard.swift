import AppKit
import CmuxNextWakeups

/// The main-thread task board the in-process CEF pump runs its passes on. Each
/// `CefDoMessageLoopWork` call is one task of owner ``ownerName`` on ``budget``: the stall watchdog
/// names it, the turn meter counts it as scheduled work, and `debug.main_budget owners` shows its
/// run times, per class. A nested run loop a pass runs (a context menu, a `<select>` popup) is not
/// the pass's time (``MainFrameBudget`` parks the task in it).
///
/// It is attribution only. A pass never asks the budget whether it may run: its class
/// (``CEFPumpSchedule/workClass(pageHasFocus:pageInputRecent:)``) is input or frame, which no input
/// response or share defers. An input-class pass takes no late frame's slice, and while a page has the
/// keyboard a pending key does not hold it (Chrome's input priority is above its rendering-starvation
/// boost: third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc).
/// Pending pointer input may go to any view under the pointer, so it still holds the pass. The fork's
/// 2 ms pump slice (`--cmux-pump-time-slice-us`) bounds each pass as before.
///
/// ```swift
/// // In process: the app's budget, the pump's one dispatch follower and the same window classifier.
/// let pages = ChromiumPageWindowClassifier()
/// let board = CEFPumpBoard(budget: mainWork.budget, dispatches: CEFPumpTapDispatches(tap: input, pages: pages),
///                          pageHasFocus: CEFPumpBoard.keyWindowIsPage(pages: pages),
///                          refreshInterval: { mainWork.frames.refreshPeriod })
/// let pump = CEFMessagePump(work: work, timer: timer, board: board)
/// ```
final class CEFPumpBoard {
    /// The board owner of every pump pass.
    nonisolated static let ownerName = "cef.pump"

    let budget: MainFrameBudget
    let owner: MainTaskOwner
    /// The end of each input's dispatch and where it went, when the pump has no input policy (the
    /// policy's own follower tells the pump otherwise). Nil: focus alone classes the pass.
    let dispatches: (any CEFPumpInputDispatches)?
    private let focus: @MainActor () -> Bool
    private let refreshInterval: @MainActor () -> TimeInterval

    /// - Parameters:
    ///   - budget: The app's main-thread budget; the owner is interned on its board here, once.
    ///   - dispatches: The input dispatch ends the pump follows for page input.
    ///   - pageHasFocus: Whether a Chromium view has the keyboard now (read at each due pass).
    ///   - refreshInterval: The frame clock's refresh interval: how long a page's input keeps the
    ///     passes in the input class (``CEFPumpSchedule/RecentPageInput``).
    init(budget: MainFrameBudget, dispatches: (any CEFPumpInputDispatches)?, pageHasFocus: @escaping @MainActor () -> Bool,
         refreshInterval: @escaping @MainActor () -> TimeInterval = { 1.0 / 60 }) {
        self.budget = budget
        owner = budget.board.owner(Self.ownerName)
        self.dispatches = dispatches
        focus = pageHasFocus
        self.refreshInterval = refreshInterval
    }

    /// Whether a Chromium view has the keyboard.
    var pageHasFocus: Bool { focus() }

    /// One refresh, 60 Hz when the frame clock reports none.
    var refresh: TimeInterval {
        let interval = refreshInterval()
        return interval.isFinite && interval > 0 ? interval : 1.0 / 60
    }

    /// A Chromium view is first responder exactly when its page window (`CefNSWindow`: a page or its
    /// DevTools) is key: each one takes key inside its cmux window so the page gets the keyboard
    /// (``ChromiumPageWindowMain``).
    static func keyWindowIsPage(keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp?.keyWindow },
                                pages: ChromiumPageWindowClassifier) -> @MainActor () -> Bool {
        return {
            guard let window = keyWindow() else { return false }
            return pages.isPage(window)
        }
    }
}

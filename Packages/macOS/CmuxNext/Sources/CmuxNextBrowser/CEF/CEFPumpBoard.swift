import AppKit
import CmuxNextInput
import CmuxNextWakeups

/// The main-thread task board the in-process CEF pump runs its passes on (p06-scheduler-048). Each
/// `CefDoMessageLoopWork` call is one task of owner ``ownerName`` on ``budget``: the stall watchdog
/// names it, the turn meter counts it as scheduled work, and `debug.main_budget owners` shows its
/// run times, per class.
///
/// It is attribution only. A pass never asks the budget whether it may run: its class
/// (``CEFPumpSchedule/workClass(pageHasFocus:pageInputUnacked:)``) is input or frame, which no input
/// response or share defers, and while a page has the keyboard or an unacked input the pump holds no
/// pass for pending input or a late frame (Chrome's input priority is above its rendering-starvation
/// boost: third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc).
/// The fork's 2 ms pump slice (`--cmux-pump-time-slice-us`) bounds each pass as before.
///
/// ```swift
/// // CEFRuntime, in process: the app's budget and input tap.
/// let board = CEFPumpBoard(budget: mainWork.budget, input: inputTap)
/// let pump = CEFMessagePump(work: work, timer: timer, starvation: board.budget.starvation, board: board)
/// ```
final class CEFPumpBoard {
    /// The board owner of every pump pass.
    nonisolated static let ownerName = "cef.pump"

    let budget: MainFrameBudget
    let owner: MainTaskOwner
    /// The end of each input's dispatch and where it went: an input delivered to a page is unacked
    /// until the next pass (nil: focus alone classes the pass).
    let dispatches: (any CEFPumpInputDispatches)?
    private let focus: @MainActor () -> Bool

    /// - Parameters:
    ///   - budget: The app's main-thread budget; the owner is interned on its board here, once.
    ///   - dispatches: The input dispatch ends the pump follows for unacked page input.
    ///   - pageHasFocus: Whether a Chromium view has the keyboard now (read at each due pass).
    init(budget: MainFrameBudget, dispatches: (any CEFPumpInputDispatches)?, pageHasFocus: @escaping @MainActor () -> Bool) {
        self.budget = budget
        owner = budget.board.owner(Self.ownerName)
        self.dispatches = dispatches
        focus = pageHasFocus
    }

    /// The app's: dispatch ends from `input` (``CEFPumpTapDispatches``), focus from the key window.
    convenience init(budget: MainFrameBudget, input: InputEventTap?) {
        self.init(budget: budget, dispatches: input.map { CEFPumpTapDispatches(tap: $0) }, pageHasFocus: Self.keyWindowIsPage())
    }

    /// Whether a Chromium view has the keyboard.
    var pageHasFocus: Bool { focus() }

    /// A Chromium view is first responder exactly when its page window (`CefNSWindow`: a page or its
    /// DevTools) is key: each one takes key inside its cmux window so the page gets the keyboard
    /// (``ChromiumPageWindowMain``). O(1), no allocation once the class is found.
    static func keyWindowIsPage(keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp?.keyWindow },
                                pageWindowClass: @escaping () -> AnyClass? = ChromiumPageWindowMain.pageClass) -> @MainActor () -> Bool {
        let page = KeyPageWindow(keyWindow: keyWindow, pageWindowClass: pageWindowClass)
        return { page.isKey }
    }

    /// The key window check with `CefNSWindow` looked up once CEF registered it.
    private final class KeyPageWindow {
        private let keyWindow: @MainActor () -> NSWindow?
        private let pageWindowClass: () -> AnyClass?
        private var pageClass: AnyClass?

        init(keyWindow: @escaping @MainActor () -> NSWindow?, pageWindowClass: @escaping () -> AnyClass?) {
            self.keyWindow = keyWindow
            self.pageWindowClass = pageWindowClass
        }

        var isKey: Bool {
            guard let window = keyWindow() else { return false }
            if pageClass == nil { pageClass = pageWindowClass() }
            guard let pageClass else { return false }
            return window.isKind(of: pageClass)
        }
    }
}

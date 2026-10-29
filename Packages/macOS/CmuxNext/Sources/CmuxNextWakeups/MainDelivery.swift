public import CmuxNextCompat
public import Foundation

/// Runs main-actor work from a callback whose thread the caller does not control: KVO, a
/// `queue: nil` notification, a completion handler or C callback with no documented thread
/// (plans/cmux-next/crash-elimination.md, P1b), as a task of a class and an owner of the one
/// main-thread scheduler (plans/cmux-next/chrome-parity/p06-scheduler.md, R-delivery).
///
/// - On the main thread the work runs inline, before ``run(file:line:_:)`` returns, so the order of
///   main-thread side effects is unchanged. It runs as a task on the scheduler's board
///   (``MainFrameBudget/runInline(_:owner:posted:_:)``): the board names its class, owner and the line
///   that delivered it, its owner ledger records it, and its time is charged to its class's frame
///   budget. It cannot wait, so it takes no turn of its class's pacing, and the board names the work
///   it ran inside (a person's action span, a scheduled task) again when it returns.
/// - Off the main thread the work is posted in its class
///   (``MainWorkScheduler/postFromAnyThread(_:owner:file:line:_:)``): it runs on main in class
///   order, yields to the person's pending input, and the board names it the same way. Chrome
///   posts a callback from another thread the same way, as a task with a `posted_from` on a typed
///   UI-thread runner (`content/public/browser/browser_task_traits.h`, `base/location.h`).
///
/// Build it once, where the scheduler is injected, and keep it with the observation:
///
/// ```swift
/// let delivery = MainDelivery(class: .visible, owner: "browser.tab.kvo", on: mainWork)
/// observation = view.observe(\.frame) { @Sendable [weak self] _, _ in
///     delivery.run { self?.layout() }
/// }
/// ```
public struct MainDelivery: Sendable {
    /// The class, owner and scheduler work goes through (nil only for the unclassed form the
    /// sites not yet migrated still build).
    private let route: Route?

    /// A delivery whose work runs in `workClass` for `owner`.
    ///
    /// - Parameters:
    ///   - workClass: `userBlocking` for the rest of a person's action, `visible` for what shows on
    ///     screen, `automation` for work an agent, the CLI or another process asked for, `background`
    ///     for work nobody sees.
    ///   - owner: The owner, interned on `scheduler`'s board (``MainTaskBoard/owner(_:)``).
    ///   - scheduler: The app's main-thread scheduler.
    public init(class workClass: BudgetedWorkClass, owner: MainTaskOwner, on scheduler: MainWorkScheduler) {
        route = Route(workClass: workClass, owner: owner, scheduler: scheduler)
    }

    /// A delivery whose work runs in `workClass` for the owner named `owner`, interned on the
    /// scheduler's board now (a lock: build the delivery once, not per callback).
    ///
    /// - Parameters:
    ///   - workClass: The work's class.
    ///   - owner: The owner's name in the board, the watchdog's records and `debug.main_budget`.
    ///   - scheduler: The app's main-thread scheduler.
    public init(class workClass: BudgetedWorkClass, owner: String, on scheduler: MainWorkScheduler) {
        self.init(class: workClass, owner: scheduler.board.owner(owner), on: scheduler)
    }

    /// A delivery with no class: its work is on no board and in no budget.
    @available(*, deprecated, message: "Name the class and owner: MainDelivery(class:owner:on:)")
    public init() {
        route = nil
    }

    /// Runs `work` now on the main thread, as a task of this delivery's class and owner; from any
    /// other thread, posts it in that class.
    ///
    /// - Parameters:
    ///   - file: The delivering file (leave the default).
    ///   - line: The delivering line (leave the default).
    ///   - work: The main-actor work.
    public func run(file: StaticString = #fileID, line: UInt = #line, _ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            // main-proof: guarded by Thread.isMainThread above
            MainActor.assumeIsolated { runAttributed(file: file, line: line, queuedNanos: nil, work) }
        } else if let route {
            route.scheduler.postFromAnyThread(route.workClass, owner: route.owner, file: file, line: line, work)
        } else {
            // The unclassed form: the main queue's next turn, on no board (timed by the main-job
            // census when one is armed; a classed post is timed by MainRunLoopBlock.perform).
            let work = Self.censused(work)
            // main-hop-allow: the delivery primitive's own off-main path
            // main-proof: DispatchQueue.main runs its blocks on the main thread
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
    }

    /// `work`, timed by the launch's main-job census when one is armed (Debug and bench builds).
    private static func censused(_ work: @escaping @MainActor @Sendable () -> Void) -> @MainActor @Sendable () -> Void {
        #if DEBUG || CMUX_BENCH_HOOKS
        return MainJobRing.installed()?.timed(work) ?? work
        #else
        return work
        #endif
    }

    /// Where a delivery's work goes.
    private struct Route: Sendable {
        let workClass: BudgetedWorkClass
        let owner: MainTaskOwner
        let scheduler: MainWorkScheduler

        /// Runs `work` now as a task of the class and owner, posted at `file`:`line` at `queuedNanos`
        /// (nil: now, an inline delivery waits for nothing). The board names its site while it runs
        /// and its owner ledger records it. It nests in a scheduled task or a person's action span, and
        /// the board names that again when it returns; it takes no turn of its class's pacing
        /// (``MainFrameBudget/runInline(_:owner:posted:_:)``).
        @MainActor func runInline(file: StaticString, line: UInt, queuedNanos: UInt64?, _ work: @MainActor () -> Void) {
            let budget = scheduler.budget
            let post = MainTaskPost(site: MainPostSite(file: file, line: line), enqueueNanos: queuedNanos ?? budget.nowNanos)
            budget.runInline(workClass.workClass, owner: owner, posted: post) { work() }
        }
    }
}

extension MainDelivery: MainBlockAttribution {
    /// Now on the scheduler budget's any-thread clock (``MainFrameBudget/postClock``), read when a
    /// ``MainRunLoopBlock`` built with this delivery is queued; nil without one (a test's
    /// main-actor clock) or for the unclassed form.
    public func queuedNanos() -> UInt64? {
        route?.scheduler.budget.postClock?()
    }

    /// Runs `body` now as a task of this delivery's class and owner (a ``MainRunLoopBlock`` built
    /// with ``MainRunLoopBlock/init(class:owner:on:file:line:_:)`` runs its body here).
    @MainActor public func runAttributed(file: StaticString, line: UInt, queuedNanos: UInt64?, _ body: @MainActor () -> Void) {
        guard let route else {
            body()
            return
        }
        route.runInline(file: file, line: line, queuedNanos: queuedNanos, body)
    }
}

extension MainRunLoopBlock {
    /// A run-loop block whose every run is a task of `workClass` for `owner` on `scheduler`'s
    /// board, with the line that built it as its site. It still runs in the run-loop callout, never
    /// inline, in the mode ``perform(mode:)`` names.
    ///
    /// ```swift
    /// let refresh = MainRunLoopBlock(class: .visible, owner: inspectorOwner, on: mainWork) { [weak self] in self?.read() }
    /// refresh.perform()
    /// ```
    ///
    /// - Parameters:
    ///   - workClass: The block's class.
    ///   - owner: Its owner, interned on `scheduler`'s board.
    ///   - scheduler: The app's main-thread scheduler.
    ///   - file: Where the block is built (leave the default).
    ///   - line: The line it is built on (leave the default).
    ///   - body: The main-actor work.
    public init(class workClass: BudgetedWorkClass, owner: MainTaskOwner, on scheduler: MainWorkScheduler,
                file: StaticString = #fileID, line: UInt = #line, _ body: @escaping @MainActor () -> Void) {
        self.init(attributedTo: MainDelivery(class: workClass, owner: owner, on: scheduler), file: file, line: line, body)
    }

    /// ``init(class:owner:on:file:line:_:)`` with the owner's name, interned on the board now.
    public init(class workClass: BudgetedWorkClass, owner: String, on scheduler: MainWorkScheduler,
                file: StaticString = #fileID, line: UInt = #line, _ body: @escaping @MainActor () -> Void) {
        self.init(attributedTo: MainDelivery(class: workClass, owner: owner, on: scheduler), file: file, line: line, body)
    }

    /// Queues `body` on the main run loop once, as a task of `workClass` for `owner`.
    ///
    /// ```swift
    /// MainRunLoopBlock.perform(class: .visible, owner: menuOwner, on: mainWork) { [weak self] in self?.popUp(menu) }
    /// ```
    ///
    /// - Parameters:
    ///   - workClass: The block's class.
    ///   - owner: Its owner, interned on `scheduler`'s board.
    ///   - scheduler: The app's main-thread scheduler.
    ///   - mode: The run loop mode to run in (default `.commonModes`).
    ///   - file: The posting file (leave the default).
    ///   - line: The posting line (leave the default).
    ///   - body: The main-actor work.
    public static func perform(class workClass: BudgetedWorkClass, owner: MainTaskOwner, on scheduler: MainWorkScheduler,
                               mode: CFRunLoopMode = .commonModes, file: StaticString = #fileID, line: UInt = #line,
                               _ body: @escaping @MainActor () -> Void) {
        MainRunLoopBlock(class: workClass, owner: owner, on: scheduler, file: file, line: line, body).perform(mode: mode)
    }
}

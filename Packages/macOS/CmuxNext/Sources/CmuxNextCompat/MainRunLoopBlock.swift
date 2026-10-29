public import Foundation

/// Main-actor work queued on the main run loop, to run on a later pass of it.
///
/// It replaces the hand-written `CFRunLoopPerformBlock(CFRunLoopGetMain(), mode)`, whose block
/// asserts the main actor with `assumeIsolated`, plus `CFRunLoopWakeUp(CFRunLoopGetMain())`: the
/// main-thread proof lives here once, and callers write a plain `@MainActor` closure. It is the
/// one raw main run-loop hop of the package; other hops (`MainRunLoopHop` in CmuxNextControl)
/// call it.
///
/// Use it when the caller must return before the work runs, and the work must run in a
/// run-loop callout instead of inside a main-queue job (a menu's tracking loop started from
/// the callout lets main-actor jobs keep running while the menu is open). In the default
/// `.commonModes` the block also runs while a menu or a drag tracks events, where a
/// default-mode block would wait for the tracking to end.
///
/// ```swift
/// MainRunLoopBlock.perform { [weak self] in
///     self?.showExtensionsMenu()
/// }
/// ```
///
/// A block can be kept and queued again, for example once per request:
///
/// ```swift
/// let refresh = MainRunLoopBlock { [weak self] in self?.refresh() }
/// refresh.perform()
/// ```
///
/// The block's work runs in a ``MainCallbackClass``: with one from the app's
/// main-thread scheduler it runs as a task of its class, and work that is not input or frame waits
/// behind a person's pending input. The default, ``MainCallbackClass/immediate``, runs it in the
/// callout with no class; it stays only until the call sites name a class (tasks 081 and 082), and
/// new code passes one.
///
/// ```swift
/// MainRunLoopBlock.perform(class: mainWork.callbackClass(.frame, owner: "menu.popUp")) { [weak self] in
///     self?.popUp(menu)
/// }
/// ```
///
/// Code that can reach the main-thread scheduler can also build the block with a class and an owner
/// (CmuxNextWakeups' `MainRunLoopBlock(class:owner:on:_:)`). It still runs in the run-loop
/// callout, and the scheduler's board names it while it runs, so the stall watchdog and
/// `debug.main_budget` attribute its time (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// R-delivery).
public nonisolated struct MainRunLoopBlock: Sendable {
    private let body: @MainActor () -> Void
    private let workClass: MainCallbackClass
    private let attribution: Attribution?

    /// Makes a block that runs `body` on the main actor each time it is performed.
    ///
    /// - Parameters:
    ///   - workClass: The class `body` runs in (default ``MainCallbackClass/immediate``: in the
    ///     callout, with no class).
    ///   - body: The main-actor work. It runs once per ``perform(mode:)``.
    public init(class workClass: MainCallbackClass = .immediate, _ body: @escaping @MainActor () -> Void) {
        self.body = body
        self.workClass = workClass
        attribution = nil
    }

    /// Makes a block that `attribution` names while each of its runs lasts (the main-thread
    /// scheduler's board, with the block's class and owner).
    ///
    /// - Parameters:
    ///   - attribution: What names the work while it runs.
    ///   - file: Where the block is built (leave the default).
    ///   - line: The line it is built on (leave the default).
    ///   - body: The main-actor work. It runs once per ``perform(mode:)``.
    public init(attributedTo attribution: any MainBlockAttribution, file: StaticString = #fileID, line: UInt = #line,
                _ body: @escaping @MainActor () -> Void) {
        self.body = body
        workClass = .immediate
        self.attribution = Attribution(by: attribution, file: file, line: line)
    }

    /// Queues the block on the main run loop and wakes the run loop, from any thread.
    ///
    /// The block runs on a later pass of the main run loop in `mode`, never inline: a caller
    /// on the main thread returns first. Each call runs the block once.
    ///
    /// - Parameter mode: The run loop mode to run in (default `.commonModes`, which includes
    ///   the default mode and the event-tracking mode of menus and drags).
    public func perform(mode: CFRunLoopMode = .commonModes) {
        #if DEBUG || CMUX_BENCH_HOOKS
        let body = Self.censused(self.body)
        #else
        let body = body
        #endif
        let workClass = workClass
        let attribution = attribution
        // The queue time is read here, on the queuing thread, so the work's wait covers its time in
        // the run loop's queue (Chrome's `PendingTask::queue_time`, set at `PostTask`).
        let queuedNanos = attribution?.by.queuedNanos()
        let main = CFRunLoopGetMain()
        // main-hop-allow: the run-loop block primitive; each caller names the AppKit order that needs it
        CFRunLoopPerformBlock(main, mode.rawValue) {
            // main-proof: a block queued on CFRunLoopGetMain() runs only on the main thread.
            MainActor.assumeIsolated {
                if let attribution {
                    attribution.by.runAttributed(file: attribution.file, line: attribution.line, queuedNanos: queuedNanos, body)
                } else {
                    workClass.run(body)
                }
            }
        }
        CFRunLoopWakeUp(main)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `body`, timed by the launch's main-job census with this post site's stack when a launch armed it
    /// (`CMUX_NEXT_MAIN_JOB_CENSUS`); unchanged otherwise, and once the census is frozen or full.
    private static func censused(_ body: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        guard let ring = MainJobRing.installed(),
              let slot = ring.recordEnqueue(.runLoopBlock, priority: MainJobRing.currentPriority) else { return body }
        return { ring.run(slot: slot) { body() } }
    }
    #endif

    /// Queues `body` on the main run loop once (``perform(mode:)`` of a new block).
    ///
    /// ```swift
    /// MainRunLoopBlock.perform { [weak self] in self?.popUp(menu) }
    /// ```
    ///
    /// - Parameters:
    ///   - mode: The run loop mode to run in (default `.commonModes`).
    ///   - workClass: The class `body` runs in (default ``MainCallbackClass/immediate``).
    ///   - body: The main-actor work.
    public static func perform(mode: CFRunLoopMode = .commonModes, class workClass: MainCallbackClass = .immediate,
                               _ body: @escaping @MainActor () -> Void) {
        MainRunLoopBlock(class: workClass, body).perform(mode: mode)
    }

    /// What names one block's runs, and where the block was built.
    private struct Attribution: Sendable {
        let by: any MainBlockAttribution
        let file: StaticString
        let line: UInt
    }
}

/// Names the work of a main-thread callout while it runs. CmuxNextWakeups' `MainDelivery`
/// conforms: it runs the work as a task of its class and owner, so the scheduler's board shows
/// the task with its class, owner and the site it came from, and the class's frame budget is
/// charged with its time.
public protocol MainBlockAttribution: Sendable {
    /// Now, on the clock the attributed work's wait is measured with, from any thread; nil when
    /// that clock may only be read on the main thread (the work's wait then starts when it runs).
    func queuedNanos() -> UInt64?

    /// Runs `body` now, on the main thread, named as this attribution's work until it returns.
    ///
    /// - Parameters:
    ///   - file: Where the work was posted or built (`#fileID`).
    ///   - line: The line it was posted or built on.
    ///   - queuedNanos: What ``queuedNanos()`` read when the work was queued.
    ///   - body: The work.
    @MainActor func runAttributed(file: StaticString, line: UInt, queuedNanos: UInt64?, _ body: @MainActor () -> Void)
}

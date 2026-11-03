public import CmuxNextWakeups

/// When the New Tab spare pool (CmuxNextApp's `NewTabSparePool`) makes its next pages: never in an open's turn or
/// frames, where making one (a web view and a Chromium browser, then its setup calls and first load: 10-40 ms of
/// main-thread tasks) dropped 4-17 refreshes per Cmd-T (PACING TRIAGE #32910). As Chrome makes its spare renderer
/// as best-effort work after the navigation it served, a handout's replacement comes after the key's frame
/// committed, the open's tab-strip motion ended and the adopted page drew its first frame in its pane, then
/// ``settle`` of idle time (input does not push it back), as one background task on the app's scheduler (it yields
/// to the person's input and to the frame's budget).
///
/// ```swift
/// let refills = AgentPaneSpareRefiller(on: mainWork) { pool.warmNow() }
/// refills.afterOpen(shown: view) { strip.whenStill($0) }
/// ```
@MainActor
public final class AgentPaneSpareRefiller {
    /// Runs its work once an open's tab-strip motion ended.
    public typealias Still = (@escaping @MainActor () -> Void) -> Void

    /// The idle time after an open settled before its replacement is made.
    public static let settle: Duration = .milliseconds(250)

    private let queue: FrameBatchQueue
    private let timer = DemandTimer(owner: "NewTabSparePool.refill")
    private let make: @MainActor () -> Void
    /// The latest open's number: an earlier open's wait that a later open overtook does nothing.
    private var generation = 0
    /// From a handout until its open settled: the pool changes no parked page meanwhile (no prepare, no make).
    public private(set) var isOpening = false

    /// - Parameters:
    ///   - work: The app's main-thread scheduler; each make is a background task on it.
    ///   - make: Runs once the latest open settled: the pool prepares its parked pages and makes one when it has room.
    public init(on work: MainWorkScheduler, make: @escaping @MainActor () -> Void) {
        queue = FrameBatchQueue(owner: "NewTabSparePool.warm", budgeted: .background, on: work)
        self.make = make
    }

    /// The pool's own quiet-input warm ran: no open is pending any more.
    /// - Returns: Whether an open was pending.
    @discardableResult
    public func settled() -> Bool {
        guard isOpening else { return false }
        generation &+= 1
        isOpening = false
        timer.cancel()
        return true
    }

    /// A spare was handed out: its replacement once the open settled. A later open restarts the wait (a rapid pair
    /// settles once, after the second open).
    ///
    /// - Parameters:
    ///   - shown: The page the open showed (its first frame in its pane ends the open), or nil.
    ///   - still: Runs its work once the open's tab-strip motion ended, or nil when there is none to wait for.
    public func afterOpen(shown: AgentPaneView?, still: Still?) {
        timer.cancel()
        generation &+= 1
        isOpening = true
        let open = generation
        AfterFrameCommit().run { [weak self, weak shown] in
            let settled: @MainActor () -> Void = { [weak self] in
                guard let self, open == generation else { return }
                timer.schedule(after: Self.settle) { @MainActor [weak self] in
                    guard let self, open == generation else { return }
                    queue.enqueue { [weak self] in
                        guard let self, open == generation else { return }
                        isOpening = false
                        make()
                    }
                }
            }
            let drawn: @MainActor () -> Void = { [weak shown] in
                if let shown { shown.redraw.afterNextFrame { settled() } } else { settled() }
            }
            guard self != nil else { return }
            if let still { still(drawn) } else { drawn() }
        }
    }
}

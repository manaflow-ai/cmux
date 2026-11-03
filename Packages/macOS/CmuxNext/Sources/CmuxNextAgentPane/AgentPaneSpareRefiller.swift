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

    /// - Parameters:
    ///   - work: The app's main-thread scheduler; each make is a background task on it.
    ///   - make: Makes one spare when the pool has room.
    public init(on work: MainWorkScheduler, make: @escaping @MainActor () -> Void) {
        queue = FrameBatchQueue(owner: "NewTabSparePool.warm", budgeted: .background, on: work)
        self.make = make
    }

    /// A spare was handed out: its replacement once the open settled.
    ///
    /// - Parameters:
    ///   - shown: The page the open showed (its first frame in its pane ends the open), or nil.
    ///   - still: Runs its work once the open's tab-strip motion ended, or nil when there is none to wait for.
    public func afterOpen(shown: AgentPaneView?, still: Still?) {
        AfterFrameCommit().run { [weak self, weak shown] in
            let settled: @MainActor () -> Void = { [weak self] in
                self?.timer.schedule(after: Self.settle) { @MainActor [weak self] in self?.enqueue() }
            }
            let drawn: @MainActor () -> Void = { [weak shown] in
                if let shown { shown.redraw.afterNextFrame { settled() } } else { settled() }
            }
            guard self != nil else { return }
            if let still { still(drawn) } else { drawn() }
        }
    }

    private func enqueue() {
        queue.enqueue { [weak self] in self?.make() }
    }
}

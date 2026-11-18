public import CmuxNextWakeups

/// When the New Tab spare pool (CmuxNextApp's `NewTabSparePool`) makes its next pages: never in an open's turn or
/// frames, where making one (a web view and a Chromium browser, then its setup calls and first load: 10-40 ms of
/// main-thread tasks) dropped 4-17 refreshes per Cmd-T (PACING TRIAGE #32910). As Chrome makes its spare renderer
/// as best-effort work after the navigation it served, a handout's replacement comes after the key's frame
/// committed, the open's tab-strip motion ended and the adopted page drew its first frame in its pane, then
/// ``settle`` of idle time (input does not push it back), as one background task on the app's scheduler (it yields
/// to the person's input and to the frame's budget).
///
/// A chat that adopts the page follows the same rule from the moment the page drew the chat
/// (``afterPaint(of:)``, decision 2026-11-16). Before, only the pool's quiet-input wait refilled after a chat, and
/// each key, click or scroll pushed that wait back, so a person who went on reading, scrolling and clicking kept the
/// pool empty.
///
/// A refill's make never runs while the person's input is under way (``Counts/heldForInput``): an input event is in
/// dispatch (a frame that comes inside a drag's or a menu's own run loop), or a scroll is under way (its gesture's
/// or its momentum's events still come; the frames that show a scroll come between its events, when none is in
/// dispatch). Such a make makes nothing and waits ``settle`` again. It does not ask every frame: a modal panel can
/// keep one event in dispatch for minutes, and a waiting make must not keep the frames running. Limit: the frame
/// after a key's dispatch is not held, so a make can run in the frame that shows that key (the frame budget makes a
/// background task yield once to input still in the queue).
///
/// A refill's make never runs while another chat's page on screen has not drawn (``Counts/heldForOpen``): a second
/// chat that found no page builds its own, and a make in that open would add its main-thread tasks to the wait
/// for that chat's content. The make waits for the first of those pages to draw, then ``settle`` again, and asks
/// again then. A page that does not draw (its tab was hidden, it closed, it never reports) is asked about again
/// after ``AgentPaneShownChatsWait/deadline``: a page that left the screen holds nothing more. A New Tab page that
/// loads holds nothing.
///
/// The pool's own quiet-input warm is not a refill: it has neither hold, and it ends a refill that waits.
///
/// ```swift
/// let refills = AgentPaneSpareRefiller(on: mainWork, inInput: { dispatch.inputUnderWay },
///                                      loading: { shownChats.loadingNow(tabs.views.values) }) { pool.warmNow() }
/// refills.afterOpen(shown: view) { strip.whenStill($0) }
/// refills.afterPaint(of: chatPage)
/// ```
@MainActor
public final class AgentPaneSpareRefiller {
    /// Runs its work once an open's tab-strip motion ended.
    public typealias Still = (@escaping @MainActor () -> Void) -> Void
    /// Runs its work once the page a chat adopted drew that chat.
    public typealias Painted = (@escaping @MainActor () -> Void) -> Void

    /// The idle time after an open settled, or after an adopted page drew its chat, before the replacement is made:
    /// the one wait of every refill. The open's own follow-up frames (the pane's cover goes, the page's settled
    /// paint, the tab strip's motion) pass first, so the make's main-thread tasks land in none of them; and it is
    /// short enough that the pool has a page again before a person's next open after a pause. The value was set for
    /// Cmd-T (PACING TRIAGE #32910). It is not tuned by a measure of chat opens yet.
    public static let settle: Duration = .milliseconds(250)

    /// What the refill's make tasks did since launch (tests read it).
    public struct Counts: Equatable, Sendable {
        /// Makes that ran, each one background task on the app's scheduler.
        public var makes = 0
        /// Times a make found the person's input under way, made nothing and waited the settle again.
        public var heldForInput = 0
        /// Times a make found a chat page on screen that had not drawn yet, made nothing and waited for its paint.
        public var heldForOpen = 0

        public init() {}
    }

    /// The make tasks' counts since launch.
    public private(set) var counts = Counts() { didSet { onCounts?(counts) } }
    /// Runs at each change of ``counts`` (tests await a make or a hold by it; nothing else reads it).
    public var onCounts: (@MainActor (Counts) -> Void)?

    private let queue: FrameBatchQueue
    private let timer: DemandTimer
    private let make: @MainActor () -> Void
    private let inInput: @MainActor () -> Bool
    private let loading: @MainActor () -> [AgentPaneShownChatsWait.WhenPainted]
    /// The latest hold for a chat that loads: only its first paint starts the settle, and a paint that comes after
    /// the make was asked again does nothing.
    private var hold = 0
    /// The latest open's number: an earlier open's wait that a later open overtook does nothing.
    private var generation = 0
    /// From a handout until its open settled: the pool changes no parked page meanwhile (no prepare, no make).
    public private(set) var isOpening = false

    /// - Parameters:
    ///   - work: The app's main-thread scheduler; each make is a background task on it.
    ///   - clock: The settle's clock (tests move it by hand).
    ///   - inInput: Whether the person's input is under way now (the app's input dispatch context): an input event
    ///     (a key, a click, a scroll) is in dispatch, or a scroll is under way. A make that would start meanwhile
    ///     waits the settle again.
    ///   - loading: The chat pages on screen that have not drawn yet, each as "runs its work once it drew"
    ///     (``AgentPaneShownChatsWait``): another chat's open that is still under way.
    ///   - make: Runs once the latest open settled: the pool prepares its parked pages and makes one when it has room.
    public init(on work: MainWorkScheduler, clock: any Clock<Duration> = ContinuousClock(), inInput: @escaping @MainActor () -> Bool = { false },
                loading: @escaping @MainActor () -> [AgentPaneShownChatsWait.WhenPainted] = { [] }, make: @escaping @MainActor () -> Void) {
        queue = FrameBatchQueue(owner: "NewTabSparePool.warm", budgeted: .background, on: work)
        timer = DemandTimer(owner: "NewTabSparePool.refill", clock: clock)
        self.inInput = inInput
        self.loading = loading
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
        let open = begin()
        AfterFrameCommit().run { [weak self, weak shown] in
            let settled: @MainActor () -> Void = { [weak self] in self?.scheduleMake(for: open) }
            let drawn: @MainActor () -> Void = { [weak shown] in
                if let shown { shown.redraw.afterNextFrame { settled() } } else { settled() }
            }
            guard self != nil else { return }
            if let still { still(drawn) } else { drawn() }
        }
    }

    /// A chat adopted the spare `shown`, which switches to the chat in place: its replacement ``settle`` after the
    /// page drew the chat. The page is asked after this turn's commit, because its adoption (which starts the
    /// chat's paint over) follows the handout in the same turn. A page that refused the chat keeps its earlier
    /// paint, so the wait ends at once; a page that never draws leaves the refill to the pool's quiet-input warm.
    public func afterPaint(of shown: AgentPaneView) {
        afterPaint { [weak shown] painted in
            AfterFrameCommit().run { [weak shown] in
                guard let shown else { return painted() }
                shown.model.whenPainted { painted() }
            }
        }
    }

    /// A chat adopted a spare: its replacement ``settle`` after `painted` ran its work (the page drew the chat).
    /// Nothing is made in the caller's turn, also when the page drew already.
    public func afterPaint(_ painted: Painted) {
        let open = begin()
        painted { [weak self] in self?.scheduleMake(for: open) }
    }

    /// A handout starts a wait and ends every earlier one.
    private func begin() -> Int {
        timer.cancel()
        generation &+= 1
        isOpening = true
        return generation
    }

    /// The open `open` settled: its make after ``settle``, unless a later open overtook it.
    private func scheduleMake(for open: Int) {
        guard open == generation else { return }
        timer.schedule(after: Self.settle) { @MainActor [weak self] in self?.enqueueMake(for: open) }
    }

    /// One background task on the app's scheduler. A frame that comes while the person's input is under way makes
    /// nothing: the make waits the settle again (the pool's quiet-input warm ends that wait when it runs first).
    /// A frame that comes while a chat page on screen has not drawn makes nothing either (``wait(for:then:)``).
    private func enqueueMake(for open: Int) {
        guard open == generation else { return }
        queue.enqueue { [weak self] in
            guard let self, open == generation else { return }
            hold &+= 1
            guard !inInput() else {
                counts.heldForInput += 1
                scheduleMake(for: open)
                return
            }
            let pages = loading()
            guard pages.isEmpty else {
                counts.heldForOpen += 1
                wait(for: pages, then: open)
                return
            }
            isOpening = false
            counts.makes += 1
            make()
        }
    }

    /// The open `open`'s make is asked again ``settle`` after the first of `pages` drew (the others are asked about
    /// then), or ``AgentPaneShownChatsWait/deadline`` from now when none drew: a page whose tab was hidden, or that
    /// closed, draws nothing and is on screen no more. One timer serves both, so a page that never draws costs one
    /// wake-up for each deadline, and the pool's quiet-input warm ends that too.
    private func wait(for pages: [AgentPaneShownChatsWait.WhenPainted], then open: Int) {
        let held = hold
        timer.schedule(after: AgentPaneShownChatsWait.deadline) { @MainActor [weak self] in self?.enqueueMake(for: open) }
        for whenPainted in pages {
            whenPainted { [weak self] in
                guard let self, held == hold else { return }
                hold &+= 1
                scheduleMake(for: open)
            }
        }
    }
}

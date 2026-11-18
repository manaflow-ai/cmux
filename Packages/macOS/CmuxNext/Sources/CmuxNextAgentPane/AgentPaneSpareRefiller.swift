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
/// for that chat's content. The make waits for those pages to draw: each paint starts ``settle`` again, and the
/// make asks again when it ends. A page that does not draw (its tab was hidden, it closed, it never reports) is
/// asked about again after ``AgentPaneShownChatsWait/deadline``: a page that left the screen holds nothing more.
/// A New Tab page that loads holds nothing.
///
/// The pool's own quiet-input warm is not a refill: it has neither hold, and it ends a refill that waits.
///
/// The refiller also holds the pool's size rule (``AgentPaneSpareDemand``, decision 2026-11-16). Each open tells it
/// (``asked()``), and it tells the pool its size. After a refill's first page, each more page of that size is made
/// at the next quiet frame, one page for each frame. ``AgentPaneSpareDemand/release`` after the last open, the pool
/// is back to its own count: the release is one background task too, and never runs while the person's input is
/// under way.
///
/// ```swift
/// let refills = AgentPaneSpareRefiller(on: mainWork, inInput: { dispatch.inputUnderWay },
///                                      loading: { shownChats.loadingNow(tabs.views.values) }, room: { pool.room },
///                                      resize: { pool.resize(to: $0) }) { pool.warmNow() }
/// refills.asked()
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
    ///
    /// Limit: those are the frames of the open that took the page, and of each chat page that held the make. A chat
    /// that built its own page and drew before the make's task asked the pages holds nothing, so when it draws less
    /// than the settle after the chat that took the page, the make comes 0 to 250 ms after its paint.
    public static let settle: Duration = .milliseconds(250)

    /// What the refill's make tasks did since launch (tests read it).
    public struct Counts: Equatable, Sendable {
        /// Makes that ran, each one background task on the app's scheduler.
        public var makes = 0
        /// Times a make or a release found the person's input under way, did nothing and waited the settle again.
        public var heldForInput = 0
        /// Times a make found a chat page on screen that had not drawn yet, made nothing and waited for its paint.
        public var heldForOpen = 0
        /// Releases that ran (the pool went back to its own count), each one background task on the app's scheduler.
        public var releases = 0

        public init() {}
    }

    /// The make tasks' counts since launch.
    public private(set) var counts = Counts() { didSet { onCounts?(counts) } }
    /// Runs at each change of ``counts`` (tests await a make or a hold by it; nothing else reads it).
    public var onCounts: (@MainActor (Counts) -> Void)?

    /// The clock of the refiller's waits. A test sets its own and moves it by hand. A wait that runs at that moment
    /// ends with no make (the pool's quiet-input warm makes that page) and the bursts' count goes, so no wait and no
    /// time of the old clock is left.
    public var clock: any Clock<Duration> {
        didSet {
            settled()
            forget()
            timer = DemandTimer(owner: timer.owner, clock: clock)
            releaseTimer = DemandTimer(owner: releaseTimer.owner, clock: clock)
            elapsed = Self.sinceNow(on: clock)
        }
    }

    private let queue: FrameBatchQueue
    private let releaseQueue: FrameBatchQueue
    private var timer: DemandTimer
    private var releaseTimer: DemandTimer
    /// The time on ``clock`` since it was set: when each open asked.
    private var elapsed: @MainActor () -> Duration
    private var demand = AgentPaneSpareDemand()
    private let make: @MainActor () -> Void
    private let inInput: @MainActor () -> Bool
    private let loading: @MainActor () -> [AgentPaneShownChatsWait.WhenPainted]
    private let room: @MainActor () -> Int
    private let resize: @MainActor (Int) -> Void
    /// The latest hold for a chat that loads: each paint of its pages starts the settle again, and a paint that
    /// comes after a make task ran again does nothing.
    private var hold = 0
    /// The latest settle's number. A make task that was queued before it does nothing: the settle asks again. So a
    /// chat that drew while a make waited for its frame gets no make in the frames that follow its paint, and the
    /// handout gets one make, not two.
    private var settles = 0
    /// The latest open's number: an earlier open's wait that a later open overtook does nothing.
    private var generation = 0
    /// From a handout until its open settled: the pool changes no parked page meanwhile (no prepare, no make).
    public private(set) var isOpening = false

    /// - Parameters:
    ///   - work: The app's main-thread scheduler; each make is a background task on it.
    ///   - clock: The settle's clock (tests move it by hand).
    ///   - inInput: Whether the person's input is under way now (the app's input dispatch context): an input event
    ///     (a key, a click, a scroll) is in dispatch, or a scroll is under way. A make or a release that would start
    ///     meanwhile waits the settle again.
    ///   - loading: The chat pages on screen that have not drawn yet, each as "runs its work once it drew"
    ///     (``AgentPaneShownChatsWait``): another chat's open that is still under way.
    ///   - room: How many pages the pool can still make now to reach its size. After a make that lowered it and left
    ///     some, the next page follows at the next quiet frame.
    ///   - resize: The pool keeps this many pages from now on (the size rule); it drops the parked ones over it.
    ///   - make: Runs once the latest open settled: the pool prepares its parked pages and makes one when it has room.
    public init(on work: MainWorkScheduler, clock: any Clock<Duration> = ContinuousClock(), inInput: @escaping @MainActor () -> Bool = { false },
                loading: @escaping @MainActor () -> [AgentPaneShownChatsWait.WhenPainted] = { [] },
                room: @escaping @MainActor () -> Int = { 0 }, resize: @escaping @MainActor (Int) -> Void = { _ in },
                make: @escaping @MainActor () -> Void) {
        queue = FrameBatchQueue(owner: "NewTabSparePool.warm", budgeted: .background, on: work)
        releaseQueue = FrameBatchQueue(owner: "NewTabSparePool.release", budgeted: .background, on: work)
        self.clock = clock
        timer = DemandTimer(owner: "NewTabSparePool.refill", clock: clock)
        releaseTimer = DemandTimer(owner: "NewTabSparePool.release", clock: clock)
        elapsed = Self.sinceNow(on: clock)
        self.inInput = inInput
        self.loading = loading
        self.room = room
        self.resize = resize
        self.make = make
    }

    /// The time on `clock` since this call.
    private static func sinceNow<C: Clock<Duration>>(on clock: C) -> @MainActor () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    // MARK: The pool's size

    /// The pages the pool keeps now, by the size rule.
    public var size: Int { demand.size }

    /// An open asked the pool for a page, also one that found none: the pool's size follows the burst, and the
    /// release comes ``AgentPaneSpareDemand/release`` after the last open.
    public func asked() {
        let before = demand.size
        let size = demand.asked(at: elapsed())
        if size != before { resize(size) }
        guard demand.isGrown else { return }
        releaseTimer.schedule(after: AgentPaneSpareDemand.release) { @MainActor [weak self] in self?.enqueueRelease() }
    }

    /// The pool's own count is `count` from now on (`debug.new_tab capacity`): the rule never goes below it.
    /// - Returns: The pages the pool keeps now.
    public func keeps(atLeast count: Int) -> Int {
        demand.floor = count
        return demand.size
    }

    /// Memory pressure dropped the pages: the bursts' count goes with them, and no release is due.
    public func forget() {
        releaseTimer.cancel()
        let before = demand.size
        demand.forget()
        if demand.size != before { resize(demand.size) }
    }

    /// One background task on the app's scheduler, as a make: the pool goes back to its own count unless an open
    /// came in the meantime. A frame that comes while the person's input is under way releases nothing: closing a
    /// page is main-thread work too.
    private func enqueueRelease() {
        releaseQueue.enqueue { [weak self] in
            guard let self else { return }
            guard !inInput() else {
                counts.heldForInput += 1
                releaseTimer.schedule(after: Self.settle) { @MainActor [weak self] in self?.enqueueRelease() }
                return
            }
            guard let size = demand.released(at: elapsed()) else { return }
            counts.releases += 1
            resize(size)
        }
    }

    // MARK: The refill

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
        settles &+= 1
        timer.schedule(after: Self.settle) { @MainActor [weak self] in self?.enqueueMake(for: open) }
    }

    /// One background task on the app's scheduler. A frame that comes while the person's input is under way makes
    /// nothing: the make waits the settle again (the pool's quiet-input warm ends that wait when it runs first).
    /// A frame that comes while a chat page on screen has not drawn makes nothing either (``wait(for:then:)``).
    /// A task whose frame comes after a later settle began makes nothing: that settle's make is the one.
    /// When the pool has room for more pages after a make that added one (the size rule), the next make is the next
    /// frame's task: one page for each frame, each with the same two holds. A make that added no page ends the row
    /// (the pool cannot make one now).
    private func enqueueMake(for open: Int) {
        guard open == generation else { return }
        let asked = settles
        queue.enqueue { [weak self] in
            guard let self, open == generation, asked == settles else { return }
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
            let before = room()
            make()
            let left = room()
            if left > 0, left < before { enqueueMake(for: open) }
        }
    }

    /// The open `open`'s make is asked again ``settle`` after the latest paint of `pages` (each paint starts the
    /// settle again, so the make lands in no page's first frames; the pages that still load then are asked about
    /// then), or ``AgentPaneShownChatsWait/deadline`` from now when none drew: a page whose tab was hidden, or that
    /// closed, draws nothing and is on screen no more. One timer serves both, so a page that never draws costs one
    /// wake-up for each deadline, and the pool's quiet-input warm ends that too.
    private func wait(for pages: [AgentPaneShownChatsWait.WhenPainted], then open: Int) {
        let held = hold
        timer.schedule(after: AgentPaneShownChatsWait.deadline) { @MainActor [weak self] in self?.enqueueMake(for: open) }
        for whenPainted in pages {
            whenPainted { [weak self] in
                guard let self, held == hold else { return }
                scheduleMake(for: open)
            }
        }
    }
}

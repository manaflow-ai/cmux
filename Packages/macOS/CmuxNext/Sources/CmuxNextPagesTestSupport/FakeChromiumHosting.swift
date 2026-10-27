public import CmuxNextDesign
public import CmuxNextPages
public import CmuxNextSettings
public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// A ``PageChromiumHosting`` that hands out ``FakeChromiumPage``s, or fails.
@MainActor
public final class FakeChromiumHosting: PageChromiumHosting {
    /// The engine preference the host reports (Chromium by default).
    public var preference: BrowserDefaultEngine = .chromium
    /// Whether Chromium is available.
    public var isAvailable = true
    /// When true, ``makePage(_:chatOpen:window:origin:)`` throws ``Refused``.
    public var fails = false
    /// Every page made, in order.
    public private(set) var made: [FakeChromiumPage] = []
    /// The pane window each page made was asked for, in the order of ``made`` (nil: a window of its own).
    public private(set) var windows: [PageChromiumWindow?] = []
    /// The origin of each page asked for, in order, as the page asked (before the engine's wait).
    public private(set) var origins: [PageChromiumOrigin] = []
    /// The launch order the fake engine follows (a test's, over the app's real one); nil: no launch runs.
    public var launchOrder: LaunchOrder?
    /// Runs on each page made, before the host gets it (a test sets ``FakeChromiumPage/answer`` here).
    public var onMade: ((FakeChromiumPage) -> Void)?
    /// The lanes the pages decode their large replies on (a test's own).
    public let work: BackgroundWork
    /// The off-screen host of ``dialogs``: what a page's notice shows (its "Page unresponsive" card).
    public let dialogHost = CmuxDialogHeadlessHost()
    /// The pages' dialog center, on ``dialogHost``.
    public let dialogs: CmuxDialogCenter

    /// How many times a page asked for the supervisor's outcome (``supervisorOutcome(then:)``).
    public private(set) var supervisorAsks = 0
    /// The answers the pages wait for, until ``finishSupervision(_:)``: like the Chromium Host's
    /// supervisor, the fake answers no page in the turn of its browser's end.
    private var supervisorWaiters: [@MainActor @Sendable (PageChromiumSupervisorOutcome) -> Void] = []

    /// While set, ``makePage(_:chatOpen:window:origin:)`` waits for its browser until ``endHeldBrowsers()``, as a
    /// page of the Chromium Host waits while the host makes its browser.
    public var holdsBrowsers = false
    /// How many ``makePage(_:chatOpen:window:origin:)`` calls wait for their browser now.
    public var heldBrowsers: Int { browserWaiters.count }
    /// Runs each time a ``makePage(_:chatOpen:window:origin:)`` call starts to wait (tests wait on it).
    public var onBrowserHeld: (() -> Void)?
    private var browserWaiters: [OnceContinuation<Void, any Error>] = []

    /// The error ``makePage(_:chatOpen:window:origin:)`` throws while ``fails`` is set.
    public struct Refused: Error {}

    /// The launch order of a test's engine: the answers of ``PageChromiumHosting/restoredOrigin(isShown:)`` and
    /// ``PageChromiumHosting/startHidden(when:_:)``, and the engine's wait before it makes a page (`CEFEngine.makeTab`).
    public struct LaunchOrder {
        public let restoredOrigin: @MainActor (_ isShown: Bool) -> PageChromiumOrigin
        public let startHidden: @MainActor (_ node: VisibilityNode, _ start: @escaping @MainActor @Sendable () -> Void) -> Void
        public let waitForStart: @MainActor (_ origin: PageChromiumOrigin) async -> Void

        public init(restoredOrigin: @escaping @MainActor (_ isShown: Bool) -> PageChromiumOrigin,
                    startHidden: @escaping @MainActor (_ node: VisibilityNode, _ start: @escaping @MainActor @Sendable () -> Void) -> Void,
                    waitForStart: @escaping @MainActor (_ origin: PageChromiumOrigin) async -> Void) {
            self.restoredOrigin = restoredOrigin
            self.startHidden = startHidden
            self.waitForStart = waitForStart
        }
    }

    /// Makes a host that serves every page.
    ///
    /// - Parameter work: The lanes for ``PageChromiumHosting/work``; by default a one-wide set of the test's own.
    public init(work: BackgroundWork = BackgroundWork(cpuWidth: 1, label: "test.fake-chromium-hosting")) {
        self.work = work
        dialogs = CmuxDialogCenter(host: dialogHost)
    }

    /// Serves every page.
    public func serves(_ page: PageDescriptor) -> Bool { true }

    /// The launch order's origin; ``PageChromiumOrigin/user`` with none.
    public func restoredOrigin(isShown: Bool) -> PageChromiumOrigin { launchOrder?.restoredOrigin(isShown) ?? .user }

    /// The launch order's hidden start; `start` at once with none.
    public func startHidden(when node: VisibilityNode, _ start: @escaping @MainActor @Sendable () -> Void) {
        guard let launchOrder else { return start() }
        launchOrder.startHidden(node, start)
    }

    /// Makes a ``FakeChromiumPage`` whose sender check answers `page`'s URL. A fake page has no Chromium window, so
    /// `chatOpen` gets no window stages.
    ///
    /// - Parameters:
    ///   - page: The page to show.
    ///   - chatOpen: The agent chat open the page shows, if any.
    ///   - window: The pane window the page joins (``windows``).
    ///   - origin: Why the page starts now (recorded in ``origins``); the page is made once ``launchOrder`` lets it.
    /// - Returns: The new page.
    /// - Throws: ``Refused`` while ``fails`` is set; ``PageChromiumStartError/browserEnded`` when
    ///   ``endHeldBrowsers()`` ended the browser it waited for.
    public func makePage(_ page: PageDescriptor, chatOpen: ChatOpenStages?, window: PageChromiumWindow?,
                         origin: PageChromiumOrigin) async throws -> any PageChromiumPage {
        if fails { throw Refused() }
        origins.append(origin)
        await launchOrder?.waitForStart(origin)
        if holdsBrowsers {
            try await withOnceThrowingContinuation { (continuation: OnceContinuation<Void, any Error>) in
                browserWaiters.append(continuation)
                onBrowserHeld?()
            }
        }
        let fake = FakeChromiumPage()
        fake.senderURL = page.url().absoluteString
        made.append(fake)
        windows.append(window)
        onMade?(fake)
        return fake
    }

    /// Counts the ask and keeps `answer` for ``finishSupervision(_:)``.
    ///
    /// - Parameter answer: Gets the outcome ``finishSupervision(_:)`` gives.
    public func supervisorOutcome(then answer: @escaping @MainActor @Sendable (PageChromiumSupervisorOutcome) -> Void) {
        supervisorAsks += 1
        supervisorWaiters.append(answer)
    }

    /// The Chromium Host ended with the browsers it was making: every ``makePage(_:chatOpen:window:origin:)`` that
    /// waits throws ``PageChromiumStartError/browserEnded`` (its task resumes after this turn).
    public func endHeldBrowsers() {
        let waiters = browserWaiters
        browserWaiters = []
        for waiter in waiters { waiter.resume(throwing: PageChromiumStartError.browserEnded) }
    }

    /// Answers every page waiting in ``supervisorOutcome(then:)`` with `outcome`, in this turn.
    ///
    /// - Parameter outcome: What the supervisor did.
    public func finishSupervision(_ outcome: PageChromiumSupervisorOutcome) {
        let waiters = supervisorWaiters
        supervisorWaiters = []
        for waiter in waiters { waiter(outcome) }
    }
}

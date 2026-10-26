public import CmuxNextPages
public import CmuxNextSettings
public import CmuxNextWakeups

/// A ``PageChromiumHosting`` that hands out ``FakeChromiumPage``s, or fails.
@MainActor
public final class FakeChromiumHosting: PageChromiumHosting {
    /// The engine preference the host reports (Chromium by default).
    public var preference: BrowserDefaultEngine = .chromium
    /// Whether Chromium is available.
    public var isAvailable = true
    /// When true, ``makePage(_:chatOpen:)`` throws ``Refused``.
    public var fails = false
    /// Every page made, in order.
    public private(set) var made: [FakeChromiumPage] = []
    /// Runs on each page made, before the host gets it (a test sets ``FakeChromiumPage/answer`` here).
    public var onMade: ((FakeChromiumPage) -> Void)?
    /// The lanes the pages decode their large replies on (a test's own).
    public let work: BackgroundWork

    /// How many times a page asked for the supervisor's outcome (``supervisorOutcome(then:)``).
    public private(set) var supervisorAsks = 0
    /// The answers the pages wait for, until ``finishSupervision(_:)``: like the Chromium Host's
    /// supervisor, the fake answers no page in the turn of its browser's end.
    private var supervisorWaiters: [@MainActor @Sendable (PageChromiumSupervisorOutcome) -> Void] = []

    /// The error ``makePage(_:chatOpen:)`` throws while ``fails`` is set.
    public struct Refused: Error {}

    /// Makes a host that serves every page.
    ///
    /// - Parameter work: The lanes for ``PageChromiumHosting/work``; by default a one-wide set of the test's own.
    public init(work: BackgroundWork = BackgroundWork(cpuWidth: 1, label: "test.fake-chromium-hosting")) {
        self.work = work
    }

    /// Serves every page.
    public func serves(_ page: PageDescriptor) -> Bool { true }

    /// Makes a ``FakeChromiumPage`` whose sender check answers `page`'s URL. A fake page has no Chromium window, so
    /// `chatOpen` gets no window stages.
    ///
    /// - Parameters:
    ///   - page: The page to show.
    ///   - chatOpen: The agent chat open the page shows, if any.
    /// - Returns: The new page.
    /// - Throws: ``Refused`` while ``fails`` is set.
    public func makePage(_ page: PageDescriptor, chatOpen: ChatOpenStages?) async throws -> any PageChromiumPage {
        if fails { throw Refused() }
        let fake = FakeChromiumPage()
        fake.senderURL = page.url().absoluteString
        made.append(fake)
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

    /// Answers every page waiting in ``supervisorOutcome(then:)`` with `outcome`, in this turn.
    ///
    /// - Parameter outcome: What the supervisor did.
    public func finishSupervision(_ outcome: PageChromiumSupervisorOutcome) {
        let waiters = supervisorWaiters
        supervisorWaiters = []
        for waiter in waiters { waiter(outcome) }
    }
}

public import CmuxNextPages
public import CmuxNextSettings

/// A ``PageChromiumHosting`` that hands out ``FakeChromiumPage``s, or fails.
@MainActor
public final class FakeChromiumHosting: PageChromiumHosting {
    /// The engine preference the host reports (Chromium by default).
    public var preference: BrowserDefaultEngine = .chromium
    /// Whether Chromium is available.
    public var isAvailable = true
    /// When true, ``makePage(_:)`` throws ``Refused``.
    public var fails = false
    /// Every page made, in order.
    public private(set) var made: [FakeChromiumPage] = []
    /// Runs on each page made, before the host gets it (a test sets ``FakeChromiumPage/answer`` here).
    public var onMade: ((FakeChromiumPage) -> Void)?

    /// When true, ``supervisorOutcome()`` waits for ``finishSupervision(_:)``, as the helper-app
    /// supervisor's restart does; false answers ``PageChromiumSupervisorOutcome/gaveUp`` at once,
    /// as the in-process engine does.
    public var supervisorWaits = false
    /// How many times a page asked for the supervisor's outcome.
    public private(set) var supervisorAsks = 0
    /// Runs on each ask, after ``supervisorAsks`` counts it (tests wait on it).
    public var onSupervisorAsk: (() -> Void)?
    private var supervisorWaiters: [CheckedContinuation<PageChromiumSupervisorOutcome, Never>] = []

    /// The error ``makePage(_:)`` throws while ``fails`` is set.
    public struct Refused: Error {}

    /// Makes a host that serves every page.
    public init() {}

    /// Serves every page.
    public func serves(_ page: PageDescriptor) -> Bool { true }

    /// Makes a ``FakeChromiumPage`` whose sender check answers `page`'s URL.
    ///
    /// - Parameter page: The page to show.
    /// - Returns: The new page.
    /// - Throws: ``Refused`` while ``fails`` is set.
    public func makePage(_ page: PageDescriptor) async throws -> any PageChromiumPage {
        if fails { throw Refused() }
        let fake = FakeChromiumPage()
        fake.senderURL = page.url().absoluteString
        made.append(fake)
        onMade?(fake)
        return fake
    }

    /// Counts the ask, then waits for ``finishSupervision(_:)`` while ``supervisorWaits`` is set,
    /// else gives up at once.
    ///
    /// - Returns: The outcome ``finishSupervision(_:)`` gives, or ``PageChromiumSupervisorOutcome/gaveUp``.
    public func supervisorOutcome() async -> PageChromiumSupervisorOutcome {
        supervisorAsks += 1
        onSupervisorAsk?()
        guard supervisorWaits else { return .gaveUp }
        return await withCheckedContinuation { supervisorWaiters.append($0) }
    }

    /// Answers every page waiting in ``supervisorOutcome()`` with `outcome`.
    ///
    /// - Parameter outcome: What the supervisor did.
    public func finishSupervision(_ outcome: PageChromiumSupervisorOutcome) {
        let waiters = supervisorWaiters
        supervisorWaiters = []
        for waiter in waiters { waiter.resume(returning: outcome) }
    }
}

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
    /// When true, ``makePage(_:chatOpen:origin:)`` throws ``Refused``.
    public var fails = false
    /// Every page made, in order.
    public private(set) var made: [FakeChromiumPage] = []
    /// The origin of each page asked for, in order, as the page asked (before the engine's wait).
    public private(set) var origins: [PageChromiumOrigin] = []
    /// The launch order the fake engine follows (a test's, over the app's real one); nil: no launch runs.
    public var launchOrder: LaunchOrder?
    /// Runs on each page made, before the host gets it (a test sets ``FakeChromiumPage/answer`` here).
    public var onMade: ((FakeChromiumPage) -> Void)?
    /// The lanes the pages decode their large replies on (a test's own).
    public let work: BackgroundWork

    /// The error ``makePage(_:chatOpen:origin:)`` throws while ``fails`` is set.
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
    ///   - origin: Why the page starts now (recorded in ``origins``); the page is made once ``launchOrder`` lets it.
    /// - Returns: The new page.
    /// - Throws: ``Refused`` while ``fails`` is set.
    public func makePage(_ page: PageDescriptor, chatOpen: ChatOpenStages?, origin: PageChromiumOrigin) async throws -> any PageChromiumPage {
        if fails { throw Refused() }
        origins.append(origin)
        await launchOrder?.waitForStart(origin)
        let fake = FakeChromiumPage()
        fake.senderURL = page.url().absoluteString
        made.append(fake)
        onMade?(fake)
        return fake
    }
}

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
    /// The origin of each page made, in order (``PageChromiumOrigin``).
    public private(set) var origins: [PageChromiumOrigin] = []
    /// The launch the pages follow (``PageChromiumHosting/launch``); nil: every page starts at once.
    public var launch: StartupScheduler?
    /// Runs on each page made, before the host gets it (a test sets ``FakeChromiumPage/answer`` here).
    public var onMade: ((FakeChromiumPage) -> Void)?
    /// The lanes the pages decode their large replies on (a test's own).
    public let work: BackgroundWork

    /// The error ``makePage(_:chatOpen:origin:)`` throws while ``fails`` is set.
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
    ///   - origin: Why the page starts now (recorded in ``origins``).
    /// - Returns: The new page.
    /// - Throws: ``Refused`` while ``fails`` is set.
    public func makePage(_ page: PageDescriptor, chatOpen: ChatOpenStages?, origin: PageChromiumOrigin) async throws -> any PageChromiumPage {
        if fails { throw Refused() }
        origins.append(origin)
        let fake = FakeChromiumPage()
        fake.senderURL = page.url().absoluteString
        made.append(fake)
        onMade?(fake)
        return fake
    }
}

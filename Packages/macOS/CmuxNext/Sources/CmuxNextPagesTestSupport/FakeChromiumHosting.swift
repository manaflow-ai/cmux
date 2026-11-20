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
    /// When true, ``makePage(_:)`` never returns until its task is cancelled (CEF never made the
    /// browser), then throws `CancellationError`.
    public var hangs = false
    /// Every page made, in order.
    public private(set) var made: [FakeChromiumPage] = []
    /// Runs on each page made, before the host gets it (a test sets ``FakeChromiumPage/answer`` here).
    public var onMade: ((FakeChromiumPage) -> Void)?
    /// A stand-in for the app's focus model (``PageChromiumHosting/focusViewChanged(_:)``); nil: none.
    public var focusModel: ((PageWebView) -> Bool)?

    /// Whether this Chromium serves the live web loop (``PageChromiumHosting/setLivePages(_:)``); off
    /// by default, like a shim without live mode.
    public var servesLivePages = false

    /// Answers ``servesLivePages``.
    public func setLivePages(_ live: Bool) -> Bool { servesLivePages }

    /// Asks ``focusModel``.
    public func focusViewChanged(_ page: PageWebView) -> Bool { focusModel?(page) ?? false }

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
        if hangs {
            // A stream nobody yields to ends only when the task is cancelled; the continuation is held.
            let (pending, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            for await _ in pending {}
            withExtendedLifetime(continuation) {}
            throw CancellationError()
        }
        let fake = FakeChromiumPage()
        fake.senderURL = page.url().absoluteString
        made.append(fake)
        onMade?(fake)
        return fake
    }
}

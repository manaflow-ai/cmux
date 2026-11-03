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
    /// A stand-in for the app's focus model (``PageChromiumHosting/focusViewChanged(_:)``); nil: none.
    public var focusModel: ((PageWebView) -> Bool)?

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
        let fake = FakeChromiumPage()
        fake.senderURL = page.url().absoluteString
        made.append(fake)
        onMade?(fake)
        return fake
    }
}

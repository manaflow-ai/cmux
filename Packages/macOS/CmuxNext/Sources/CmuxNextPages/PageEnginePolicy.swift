public import CmuxNextSettings
public import Foundation

/// Picks the engine of a cmux page: the one rule behind every web view the page host makes.
///
/// `browser.defaultEngine` (Chromium unless set to WebKit) is the one setting for browser tabs
/// and cmux's own pages. A page follows it unless the page cannot run in Chromium yet
/// (``PageWebKitReason``), and Chromium must be available. Pure: the inputs are values, so tests
/// enumerate every case.
///
/// ```swift
/// let decision = PageEnginePolicy(preference: .chromium, chromiumAvailable: true)
///     .decide(for: .history, options: .standard)
/// // decision.engine == .cef
/// ```
public nonisolated struct PageEnginePolicy: Sendable, Hashable {
    /// The person's `browser.defaultEngine`.
    public var preference: BrowserDefaultEngine
    /// Whether Chromium can host a page now (the build ships it and it has not failed to start).
    public var chromiumAvailable: Bool
    /// Whether Chromium's page scheme serves the page being decided (``PageChromiumHosting/serves(_:)``).
    public var chromiumServes: Bool
    /// Whether `web-dev.json` points pages at a dev server or an overlay (``WebDevOverride/isActive``),
    /// which only WebKit pages read.
    public var liveWebOverride: Bool

    /// - Parameters:
    ///   - preference: The person's `browser.defaultEngine`.
    ///   - chromiumAvailable: Whether Chromium can host a page now.
    ///   - chromiumServes: Whether Chromium's page scheme serves the page; true by default, for a
    ///     caller that only asks about the setting and the page's own blockers.
    ///   - liveWebOverride: Whether a live web override is in force (Debug, NIGHTLY and cmux NEXT DEV only).
    public init(preference: BrowserDefaultEngine, chromiumAvailable: Bool, chromiumServes: Bool = true,
                liveWebOverride: Bool = false) {
        self.preference = preference
        self.chromiumAvailable = chromiumAvailable
        self.chromiumServes = chromiumServes
        self.liveWebOverride = liveWebOverride
    }

    /// The engine of `page` made with `options`.
    ///
    /// - Parameters:
    ///   - page: The page to show.
    ///   - options: The engine options it is made with (``PageEngineOptions/requiresWebKit``).
    /// - Returns: Chromium, or WebKit with the reason.
    public func decide(for page: PageDescriptor, options: PageEngineOptions) -> PageEngineDecision {
        guard preference == .chromium else { return .webKit(.personChoseWebKit) }
        let blocker = options.chromiumAgentChat && page.chromiumBlocker == .agentChat ? nil : page.chromiumBlocker
        if let reason = blocker ?? options.requiresWebKit { return .webKit(reason) }
        guard !liveWebOverride else { return .webKit(.liveWebOverride) }
        guard chromiumAvailable else { return .webKit(.chromiumUnavailable) }
        guard chromiumServes else { return .webKit(.notServedByChromium) }
        return .chromium
    }
}

nonisolated extension PageDescriptor {
    /// Why this page cannot run in Chromium yet, nil when it can (``PageEnginePolicy``).
    public var chromiumBlocker: PageWebKitReason? {
        if isAgentPage { return .agentChat }
        return nil
    }

    var isAgentPage: Bool { id == Self.agentPageID }

    /// The agent page's id (its descriptor lives in CmuxNextAgentPane, above this module).
    private static let agentPageID = "cmux.agent"
}

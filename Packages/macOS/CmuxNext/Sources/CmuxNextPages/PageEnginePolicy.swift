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

    /// - Parameters:
    ///   - preference: The person's `browser.defaultEngine`.
    ///   - chromiumAvailable: Whether Chromium can host a page now.
    ///   - chromiumServes: Whether Chromium's page scheme serves the page; true by default, for a
    ///     caller that only asks about the setting and the page's own blockers.
    public init(preference: BrowserDefaultEngine, chromiumAvailable: Bool, chromiumServes: Bool = true) {
        self.preference = preference
        self.chromiumAvailable = chromiumAvailable
        self.chromiumServes = chromiumServes
    }

    /// The engine of `page` made with `options`.
    ///
    /// - Parameters:
    ///   - page: The page to show.
    ///   - options: The engine options it is made with (``PageEngineOptions/requiresWebKit``).
    /// - Returns: Chromium, or WebKit with the reason.
    public func decide(for page: PageDescriptor, options: PageEngineOptions) -> PageEngineDecision {
        guard preference == .chromium else { return .webKit(.personChoseWebKit) }
        if let reason = page.chromiumBlocker ?? options.requiresWebKit { return .webKit(reason) }
        guard chromiumAvailable else { return .webKit(.chromiumUnavailable) }
        guard chromiumServes else { return .webKit(.notServedByChromium) }
        return .chromium
    }
}

nonisolated extension PageDescriptor {
    /// Why this page cannot run in Chromium yet, nil when it can (``PageEnginePolicy``).
    public var chromiumBlocker: PageWebKitReason? {
        if id == Self.agentPageID { return .agentChat }
        if !dynamicPrefixes.isEmpty { return .runtimeResources }
        return nil
    }

    /// The agent page's id (its descriptor lives in CmuxNextAgentPane, above this module).
    private static let agentPageID = "cmux.agent"
}

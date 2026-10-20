public import Foundation

/// The engine one cmux page shows in, and why when it is WebKit although Chromium was asked for.
public nonisolated struct PageEngineDecision: Sendable, Hashable {
    /// The engine that shows the page.
    public var engine: PageHostEngine
    /// Set when ``engine`` is WebKit for a reason other than nothing having asked for Chromium.
    public var webKitReason: PageWebKitReason?

    /// - Parameters:
    ///   - engine: The engine that shows the page.
    ///   - webKitReason: Why the page is on WebKit, nil for Chromium.
    public init(engine: PageHostEngine, webKitReason: PageWebKitReason? = nil) {
        self.engine = engine
        self.webKitReason = webKitReason
    }

    /// This decision for a view that can show only WebKit (a pooled spare): WebKit, keeping the
    /// reason, or with none when the policy picked Chromium.
    public var webKitOnly: PageEngineDecision {
        engine == .webKit ? self : PageEngineDecision(engine: .webKit)
    }

    /// Chromium.
    public static let chromium = PageEngineDecision(engine: .cef)

    /// WebKit, for `reason`.
    public static func webKit(_ reason: PageWebKitReason) -> PageEngineDecision {
        PageEngineDecision(engine: .webKit, webKitReason: reason)
    }
}

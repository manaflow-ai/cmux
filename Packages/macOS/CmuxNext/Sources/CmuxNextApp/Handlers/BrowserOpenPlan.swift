import CmuxNextActions
import CmuxNextBrowser
import CmuxNextWindowRules
import Foundation

/// What `openBrowser` (TabLifecycle.newBrowser) does with its `url` and
/// `engine` arguments, before any pane or daemon work. The rule is Rust's
/// (cmux-window-rules `tabs::browser_open`); this reads the URL resolver's
/// answers for both engines (Foundation's URL parsing stays here) and maps
/// a refusal to its text.
nonisolated struct BrowserOpenPlan: Equatable, Sendable {
    nonisolated enum Outcome: Equatable, Sendable {
        case refuse(String)
        case open(BrowserOpenPlan)
        /// `chrome://settings`: Settings > Browser opens instead of a tab (ChromiumPageRoute).
        case browserSettings
        /// `chrome://password-manager`: the Passwords page opens instead of a tab (ChromiumPageRoute).
        case passwordsPage
    }

    /// The page to load; nil opens the default page.
    var url: URL?
    /// The engine the tab opens with: the caller's, or Chromium for a Chromium internal page.
    var engine: String?

    @MainActor
    static func make(url text: String?, engine requested: String?, origin: ActionOrigin) -> Outcome {
        let typed = text.flatMap { ChromiumInternalURL(typed: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } != nil
        let facts = WindowRules.BrowserOpenFacts(
            hasText: text != nil, engine: requested, agent: origin != .user, chromiumInternal: typed,
            cmuxOwned: text.flatMap { ChromiumPageRoute(typed: $0) }?.isCmuxOwned == true,
            webkit: text.flatMap { resolution($0, chromium: false) }, chromium: text.flatMap { resolution($0, chromium: true) }
        )
        switch WindowRules().browserOpen(facts) {
        case .refuse("agentChromiumPage")?: return .refuse(MiscHandlerStrings.agentChromiumPage)
        case .refuse?, nil: return .refuse(MiscHandlerStrings.invalidURL(text ?? ""))
        case .open(let url, let engine)?: return .open(BrowserOpenPlan(url: url.flatMap(URL.init(string:)), engine: engine))
        case .browserSettings?: return .browserSettings
        case .passwordsPage?: return .passwordsPage
        }
    }

    /// `text` resolved for a Chromium or a WebKit tab, with its agent policy and its page route.
    private static func resolution(_ text: String, chromium: Bool) -> WindowRules.Resolution? {
        guard let url = BrowserURLResolver(allowsChromiumSchemes: chromium).url(for: text) else { return nil }
        let (route, page): (String?, String?) = switch ChromiumPageRoute(url) {
        case .cmuxPage(let page)?: ("cmuxPage", page.absoluteString)
        case .browserSettings?: ("browserSettings", nil)
        case .passwordsPage?: ("passwordsPage", nil)
        case .chromium?: ("chromium", nil)
        case nil: (nil, nil)
        }
        return WindowRules.Resolution(url: url.absoluteString, agentRefuses: AgentURLPolicy.refuses(url), route: route, page: page)
    }
}

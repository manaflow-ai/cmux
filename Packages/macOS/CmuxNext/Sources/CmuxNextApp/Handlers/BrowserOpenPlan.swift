import CmuxNextActions
import CmuxNextBrowser
import Foundation

/// What `openBrowser` (TabLifecycle.newBrowser) does with its `url` and
/// `engine` arguments, before any pane or daemon work. Pure, so every path
/// that opens a browser tab from text shares one guard. The plan is plain
/// data (nonisolated, so its Equatable conformance is too); `make` runs on
/// the main actor.
nonisolated struct BrowserOpenPlan: Equatable, Sendable {
    nonisolated enum Outcome: Equatable, Sendable {
        case refuse(String)
        case open(BrowserOpenPlan)
    }

    /// The page to load; nil opens the default page.
    var url: URL?
    /// The engine the tab opens with: the caller's, or Chromium for a
    /// Chromium internal page.
    var engine: String?
    /// The engine remembered as the user's choice for the folder: the
    /// caller's only, so one chrome:// page does not make every later Cmd-T
    /// a Chromium tab.
    var recordedEngine: String?

    @MainActor
    static func make(url text: String?, engine requested: String?, origin: ActionOrigin) -> Outcome {
        var engine = requested
        // A Chromium internal page opens in a Chromium tab (never searched in WebKit).
        if engine == nil, let text, ChromiumInternalURL(typed: text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            engine = BrowserEngineTag.cef.rawValue
        }
        var url: URL?
        if let text {
            let chromium = engine == BrowserEngineTag.cef.rawValue
            guard let resolved = BrowserURLResolver(allowsChromiumSchemes: chromium).url(for: text) else {
                return .refuse(MiscHandlerStrings.invalidURL(text))
            }
            // Agents never open Chromium's own pages (plans/cmux-next/passwords.md, section 2).
            if origin != .user, AgentURLPolicy.refuses(resolved) {
                return .refuse(MiscHandlerStrings.agentChromiumPage)
            }
            url = resolved
        }
        return .open(BrowserOpenPlan(url: url, engine: engine, recordedEngine: requested))
    }
}

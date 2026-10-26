public import Foundation
import CmuxNextBrowser
import CmuxNextDaemon

/// Where a new browser tab of a pane's machine goes (cx-2cob): the machine's daemon when it serves
/// browser tabs; a refusal with the machine's name when another machine is not connected; else
/// this Mac's session-local tab (a Cloud image whose cmux-tui predates daemon browser tabs).
public nonisolated enum BrowserTabRoute: Equatable, Sendable {
    /// The machine's daemon makes the tab (`new-frontend-browser-tab`).
    case daemon
    /// A WebKit page this app keeps for the session, with no daemon record.
    case sessionLocal
    /// Another machine that is not connected: refused, naming it.
    case refuseNotConnected

    /// The route for a pane of a machine that `isLocal` (this Mac), is `connected`, and whose
    /// daemon `servesTabs` (`frontend-browser-tabs-v1`).
    public init(isLocal: Bool, connected: Bool, servesTabs: Bool) {
        if !isLocal && !connected { self = .refuseNotConnected } else { self = servesTabs ? .daemon : .sessionLocal }
    }

    /// Whether a session-local (WebKit) tab may stand in when the daemon cannot make browser
    /// tabs. Never for a Chromium request or a Chromium internal page: those are refused rather
    /// than shown by the wrong engine.
    public static func allowsSessionLocalTab(url: URL?, requested: String?) -> Bool {
        if CmuxNextDaemon.BrowserEngine(requested: requested) == .cef { return false }
        return !(url.map(ChromiumInternalURL.needsChromium) ?? false)
    }
}

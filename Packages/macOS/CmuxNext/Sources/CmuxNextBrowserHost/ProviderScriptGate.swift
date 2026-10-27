import CmuxNextBrowser
import CmuxNextBrowserAutomation
import Foundation

/// The Secure Store login guard on the browser host's paths (cmux
/// https://github.com/manaflow-ai/cmux/issues/25830): agent code that reaches a page through the
/// host (a `frame.evaluate`, a cookie write, a raw DevTools relay) is refused on a site holding a
/// filled sign-in, and the site it ran on never gets a fill. The app answers with the same guard
/// its control socket uses, so both paths share one record of sites.
@MainActor
public protocol ProviderScriptGate: AnyObject {
    /// Before agent code runs on a tab: nil admits it (the tab's site is marked); else why not.
    func admitAgentCode(targetID: String) async -> String?
    /// After that code ran: the site the tab is on now (it may have navigated) is marked too.
    func agentCodeRan(targetID: String) async
    /// Before a raw DevTools relay attaches to a tab: nil admits it (the tab never gets a fill,
    /// and its site is marked); else why not.
    func admitRawDevTools(targetID: String) async -> String?
    /// Each raw DevTools message, in order: nil sends it (the tab's current site is marked); else
    /// why it is refused (the tab is on a site holding a filled sign-in, or its site is unknown
    /// while one is filled).
    func rawDevToolsMessage(targetID: String) -> String?
}

extension BrowserHostProvider {
    /// Whether a driver call runs the agent's own code in the page: a `frame.evaluate` outside the
    /// host's own world, or a cookie write.
    nonisolated static func runsAgentCode(_ method: String, _ params: DriverJSON) -> Bool {
        switch method {
        case "cookies.set", "cookies.clear": return true
        case "frame.evaluate":
            if case .object(let fields) = params, fields["world"] == .string("host") { return false }
            return true
        default: return false
        }
    }
}

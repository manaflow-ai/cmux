public import CmuxNextSettings

/// One page operation on a browser tab the app hosts (WebKit or Chromium).
/// The daemon owns the tab's placement; the app owns its page, so page
/// commands for app browser tabs come here (plans/cmux-next/cli.md, C9).
public enum BrowserPageOperation: Sendable, Hashable {
    case navigate(String)
    case back, forward, reload
    /// Result: `{"url": …, "title": …}`.
    case state
    /// Result: `{"value": <JSON>}`.
    case evaluate(String)
}

/// Runs page operations for the app. The App hops to the main actor itself;
/// the request deadline bounds the call.
public protocol BrowserPageEngine: Sendable {
    /// `tabID` is the tab's public id (`tab_…`); `url` is the tab's last
    /// known URL, for an engine that must load the page first.
    func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue
}

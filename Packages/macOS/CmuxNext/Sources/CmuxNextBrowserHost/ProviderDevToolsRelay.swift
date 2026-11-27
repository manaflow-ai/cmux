public import CmuxNextBrowser
import Foundation

/// The raw DevTools relay of CEF tabs (the app's CEF runtime).
@MainActor
public protocol ProviderDevToolsRelay: AnyObject {
    /// The agent's first touch of a CEF tab (`cdp.attach`): the tab becomes
    /// agent-driven (saved passwords never fill, its popups too), a live page
    /// that was not agent-driven is rebuilt, and a page that was never shown
    /// gets its browser created in the background. True once the tab's
    /// browser exists; false when the tab is not a CEF tab or cannot start.
    func prepareRelay(targetID: String) async -> Bool
    /// Relays the tab's raw DevTools messages to `onMessage` until
    /// `stopRelay`; `onEnd` runs once if the browser goes away first.
    func startRelay(targetID: String, onMessage: @escaping (String) -> Void, onEnd: @escaping () -> Void) -> Bool
    func send(targetID: String, message: String) -> CEFDevToolsRawSend
    func stopRelay(targetID: String)
}

/// Runs before the first agent action on a tab (lease start, `cdp.attach`,
/// first `call`): the tab is marked agent-driven, so saved passwords are
/// never filled into it again. Idempotent.
@MainActor
public protocol ProviderAgentMarking: AnyObject {
    func agentWillDrive(targetID: String)
}

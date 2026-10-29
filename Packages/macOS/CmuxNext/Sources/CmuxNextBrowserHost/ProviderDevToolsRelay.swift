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
    /// Why the last ``prepareRelay(targetID:)`` of `targetID` returned false, when the relay knows a reason
    /// the agent can act on (its page's wake was deferred under memory pressure); nil for the generic failure.
    func prepareFailure(targetID: String) -> String?
    /// The tab's page as the app's Chromium Host relays it to the browser host by itself (`cdp.prepare`),
    /// after ``prepareRelay(targetID:)`` made it ready; nil when the app must relay it.
    func directTarget(targetID: String) -> CEFAgentDirectTarget?
    /// A driven tab whose page no pane shows any more renders in the off-screen render window, so a capture
    /// command gets a frame. The app's own relay checks this on every send; a tab the Chromium Host relays
    /// (``directTarget(targetID:)``) sends nothing through the app, so the provider asks before each capture vote.
    func keepRendering(targetID: String)
}

extension ProviderDevToolsRelay {
    public func prepareFailure(targetID: String) -> String? { nil }
    /// A relay with no Chromium Host relays every tab itself.
    public func directTarget(targetID: String) -> CEFAgentDirectTarget? { nil }
    /// A relay without render windows keeps nothing rendering.
    public func keepRendering(targetID: String) {}
}

/// Where the app's Chromium Host gets the browser host's relay link: set after each
/// accepted `hello`, from that connection's credentials; nil ends it.
@MainActor
public protocol ProviderRelayLinking: AnyObject {
    func setRelayLink(_ link: ChromiumHostRelayLink?)
}

/// The supervisor's relay link box takes the provider's link for every Chromium Host it starts.
extension ChromiumHostAgentRelay: ProviderRelayLinking {}

/// Runs before the first agent action on a tab (lease start, `cdp.attach`,
/// first `call`): the tab is marked agent-driven, so saved passwords are
/// never filled into it again. Idempotent.
@MainActor
public protocol ProviderAgentMarking: AnyObject {
    func agentWillDrive(targetID: String)
}

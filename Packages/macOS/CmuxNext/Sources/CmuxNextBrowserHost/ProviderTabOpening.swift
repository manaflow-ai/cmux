public import CmuxNextBrowserAutomation
import Foundation

/// Opens a tab for a Chromium (`cef`) session's `tabs.open`. The app picks
/// the place (browser-host.md, D12) and answers the new tab's id once
/// `providerTabs` lists it. WebKit sessions open tabs through the WebKit
/// driver, which needs the page for its own session state.
///
/// An agent session's opt-in incognito (`tabs.open {incognito: true, session}`, either engine; decision D1 keeps
/// the person's login as the agents' default): the tab opens in the session's own in-memory store, in a background
/// incognito workspace of the session's, and `session.ended` closes that workspace and drops the store.
@MainActor
public protocol ProviderTabOpening: AnyObject {
    func openProviderTab(engine: ProviderEngine, url: String?) async throws(DriverError) -> String
    /// A blank tab of `engine` in agent session `session`'s own in-memory store; its id once announced.
    func openIncognitoProviderTab(engine: ProviderEngine, session: String) async throws(DriverError) -> String
    /// Session `session` ended: its workspace closes and its store is dropped (once its pages closed).
    func endIncognitoSession(_ session: String) async
    /// The host link ended: every session's workspace closes and its store is dropped.
    func endIncognitoSessions() async
}

public extension ProviderTabOpening {
    func openIncognitoProviderTab(engine: ProviderEngine, session: String) async throws(DriverError) -> String {
        throw DriverError(.unsupported, "tabs.open: this app opens no incognito tab for agents")
    }

    func endIncognitoSession(_ session: String) async {}

    func endIncognitoSessions() async {}
}

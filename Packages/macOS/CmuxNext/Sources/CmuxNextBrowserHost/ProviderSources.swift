public import CmuxNextBrowserAutomation
import Foundation

/// The provider endpoint, from the daemon. Nil until the daemon offers it;
/// the provider then stays idle until `credentialsChanged()`.
@MainActor
public protocol ProviderCredentialsSource: AnyObject {
    func providerCredentials() async -> ProviderCredentials?
}

/// Every browser tab the app renders. Read inside Observation tracking:
/// a change to any observable state the getter reads makes the provider
/// diff the list again (`tab.announced`, `tab.navigated`, `tab.gone`).
/// State that is not observable is pushed with `refreshTabs()`.
@MainActor
public protocol ProviderTabSource: AnyObject {
    var providerTabs: [ProviderTab] { get }
}

/// The extension access of a CEF tab, read inside Observation tracking
/// (the profile's extension store and the page URL are observable).
@MainActor
public protocol ProviderAccessSource: AnyObject {
    func access(forTab targetID: String) -> ProviderTabAccess
}

/// Opens a tab for a Chromium (`cef`) session's `tabs.open`. The app picks
/// the place (browser-host.md, D12) and answers the new tab's id once
/// `providerTabs` lists it. WebKit sessions open tabs through the WebKit
/// driver, which needs the page for its own session state.
@MainActor
public protocol ProviderTabOpening: AnyObject {
    func openProviderTab(engine: ProviderEngine, url: String?) async throws(DriverError) -> String
}

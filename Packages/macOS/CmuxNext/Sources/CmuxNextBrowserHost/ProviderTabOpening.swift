public import CmuxNextBrowserAutomation
import Foundation

/// Opens a tab for a Chromium (`cef`) session's `tabs.open`. The app picks
/// the place (browser-host.md, D12) and answers the new tab's id once
/// `providerTabs` lists it. WebKit sessions open tabs through the WebKit
/// driver, which needs the page for its own session state.
@MainActor
public protocol ProviderTabOpening: AnyObject {
    func openProviderTab(engine: ProviderEngine, url: String?) async throws(DriverError) -> String
}

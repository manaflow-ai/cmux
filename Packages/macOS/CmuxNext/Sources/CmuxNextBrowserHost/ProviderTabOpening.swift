public import CmuxNextBrowserAutomation
import Foundation

/// Opens a tab for a Chromium (`cef`) session's `tabs.open`. The app picks
/// the place (browser-host.md, D12): beside the session's caller (`place`),
/// else the focused pane. It answers the new tab's id once
/// `providerTabs` lists it. WebKit sessions open tabs through the WebKit
/// driver, which needs the page for its own session state.
@MainActor
public protocol ProviderTabOpening: AnyObject {
    func openProviderTab(engine: ProviderEngine, url: String?, place: AutomationTabPlace) async throws(DriverError) -> String
}

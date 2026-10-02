public import CmuxNextBrowser
public import Foundation
public import WebKit

/// One WebKit tab the driver may drive, as the App layer lists it.
public struct AutomationTab {
    public let tab: WebKitTab
    /// The workspace or window that shows the tab (`windowId` on the wire).
    public let windowID: String
    /// Whether the tab is the selected tab of its pane.
    public let isActive: Bool
    public let openerID: BrowserTabID?

    public init(tab: WebKitTab, windowID: String, isActive: Bool, openerID: BrowserTabID? = nil) {
        self.tab = tab
        self.windowID = windowID
        self.isActive = isActive
        self.openerID = openerID
    }
}

/// What the driver needs from the App layer, which owns tabs and layout
/// (the workspace store owns tab records; the App renders pages). The App
/// fills it; tests use a fake. Opening never changes focus or selection
/// unless the caller passes `focus` (OWNERSHIP-PRINCIPLES "Clients are
/// projections").
@MainActor
public protocol AutomationTabProvider: AnyObject {
    /// WebKit tabs of the session's workspace first, then (with `all`) of
    /// every other workspace and window.
    func automationTabs(all: Bool) -> [AutomationTab]
    /// Opens a background WebKit tab in the session's workspace.
    func openAutomationTab(url: URL?) async throws -> WebKitTab
    /// Closes a tab the session opened or claimed.
    func closeAutomationTab(_ id: BrowserTabID)
    /// Selects a tab in its pane; only for calls with origin `user` or `focus`.
    func activateAutomationTab(_ id: BrowserTabID)
}

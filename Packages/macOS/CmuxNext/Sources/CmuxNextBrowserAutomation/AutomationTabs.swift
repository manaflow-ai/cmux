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
    /// A session's end closes tab `id` (either engine), which the session created and did not
    /// keep (`tabs.close {reason: session_end}`): through the store, not offered by Reopen Closed.
    /// False when the app keeps the tab (not one of its drivable tabs, or a daemon that cannot
    /// mark the close).
    func endSessionTab(_ id: String) -> Bool
    /// Selects a tab in its pane; only for calls with origin `user` or `focus`.
    func activateAutomationTab(_ id: BrowserTabID)
    /// Keeps a tab that no pane shows rendering in a window nobody sees, so
    /// trusted input, animation frames, focus and snapshots work. Nothing is
    /// shown and no focus moves. True when the tab moved into a window now.
    func keepRendering(_ tab: WebKitTab) async -> Bool
}

public extension AutomationTabProvider {
    /// An App with no render window: hidden tabs stay as they are.
    func keepRendering(_ tab: WebKitTab) async -> Bool { false }
}

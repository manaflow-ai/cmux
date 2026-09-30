import CmuxNextControl
import CmuxNextSettings

/// `browser.page.*` (CmuxNextControl/Browser) for the app's browser tabs.
nonisolated struct AppBrowserPageEngine: BrowserPageEngine {
    unowned let services: AppServices

    func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
        try await AppBrowserPage.run(operation, tabID: tabID, services: services)
    }
}

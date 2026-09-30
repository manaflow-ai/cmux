import CmuxNextControl
import CmuxNextSettings

/// `browser.page.*` (CmuxNextControl/Browser) runs on the same page seam as
/// the compat verbs until the compat layer is deleted (plans/cmux-next/cli.md).
extension AppCompatFrontend: BrowserPageEngine {
    nonisolated func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
        try await browser(tabID: tabID, url: url, operation: operation)
    }
}

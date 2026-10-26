public import CmuxNextSettings
import Foundation

/// `browser.page.mirror` (`cmux browser <tab_…> mirror`): lists a browser tab
/// in a second pane too (plans/cmux-next/shared-browser-tabs.md).
extension BrowserPageService {
    func mirrorMethod() -> ControlMethod {
        .async("browser.page.mirror") { _ in
            throw ControlError(code: "unavailable", message: "browser.page.mirror is not served yet")
        }
    }
}

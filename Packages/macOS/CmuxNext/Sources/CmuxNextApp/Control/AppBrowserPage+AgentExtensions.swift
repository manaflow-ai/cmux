import CmuxNextBrowser
import CmuxNextControl
import Foundation

extension AppBrowserPage {
    /// Stub (plans/cmux-next/passwords.md, section 3.4); the refusal lands next.
    static func agentExtensionRefusal(_ operation: BrowserPageOperation, target: URL?, page: any BrowserTab,
                                      allowedByPerson: Bool, access: AgentExtensionAccess) -> ControlError? {
        nil
    }
}

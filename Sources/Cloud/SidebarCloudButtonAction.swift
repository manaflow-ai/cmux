import Foundation
import CmuxCloud
import CmuxProductAnalytics

/// Reveals Cloud on every press, introducing it explicitly while activation is off.
@MainActor
struct SidebarCloudButtonAction {
    let isAvailable: () -> Bool
    let isEnabled: () -> Bool
    let revealMachines: () -> Void
    let presentIntroduction: () -> Void
    var analytics: ProductAnalytics = .disabled

    func perform() {
        guard isAvailable() else { return }
        revealMachines()
        if !isEnabled() {
            // Before the card opens, so the click precedes its welcome events.
            analytics.track(.cloudButtonClicked(action: .introduceCloud))
            presentIntroduction()
        } else {
            analytics.track(.cloudButtonClicked(action: .openCloud))
        }
    }
}

/// Whether the sidebar footer Cloud button is shown.
///
/// A signed-in account whose known plan lacks Cloud access is hidden: its
/// machine creates are refused with HTTP 402 `vm_requires_pro`, so the button
/// only leads to a dead end. Signed-out Macs and accounts whose plan is not
/// loaded yet keep the button, so the welcome card can still introduce Cloud.
enum SidebarCloudButtonVisibility {
    /// - Parameters:
    ///   - showsSetting: The "Show Cloud and Device Icons in Sidebar" setting.
    ///   - isAvailable: Managed policy allows Cloud on this Mac.
    ///   - billing: The account's known plan, or nil when none is known.
    static func shows(showsSetting: Bool, isAvailable: Bool, billing: BillingPlanState?) -> Bool {
        guard showsSetting, isAvailable else { return false }
        guard let billing, billing.accountID != nil else { return true }
        return billing.isPro
    }
}

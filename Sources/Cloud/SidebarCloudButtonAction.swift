import Foundation
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

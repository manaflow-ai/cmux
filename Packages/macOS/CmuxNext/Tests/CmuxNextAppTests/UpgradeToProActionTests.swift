import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

/// Upgrade to cmux Pro (`palette.pro.upgrade`, `cmux pro upgrade`): it opens
/// the cmux pricing page (checkout runs on the web, no payment in the app)
/// instead of showing "needs app capability account-billing".
@MainActor @Suite(.serialized)
struct UpgradeToProActionTests {
    @Test func upgradeToProIsAvailableAndOpensThePricingPage() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.unavailableReason(for: "palette.pro.upgrade") == nil, "Upgrade to cmux Pro is still greyed out")
        #expect(UpgradeToPro.pricingURL.scheme == "https")
        #expect(UpgradeToPro.pricingURL.host == "cmux.com")
        #expect(UpgradeToPro.pricingURL.path == "/pricing")
    }
}

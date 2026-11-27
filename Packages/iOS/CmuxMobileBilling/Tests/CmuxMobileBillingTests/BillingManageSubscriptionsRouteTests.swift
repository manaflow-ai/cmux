import Foundation
import Testing
@testable import CmuxMobileBilling

@Suite struct BillingManageSubscriptionsRouteTests {
    @Test func anIPhoneOrIPadUsesStoreKitsSheet() {
        #expect(BillingManageSubscriptionsRoute.route(isiOSAppOnMac: false) == .storeKitSheet)
    }

    /// StoreKit refuses the sheet for the iOS app on a Mac ("The manage
    /// subscriptions sheet is not supported on Catalyst apps", then
    /// StoreKitError.unknown; Sandbox run on cmux15, macOS 27.0.1,
    /// 2026-11-18), so the button opened nothing there.
    @Test func theIOSAppOnAMacOpensTheAppStoreSubscriptionsPage() {
        let route = BillingManageSubscriptionsRoute.route(isiOSAppOnMac: true)
        #expect(route == .appStorePage(URL(string: "itms-apps://apps.apple.com/account/subscriptions")!))
    }
}

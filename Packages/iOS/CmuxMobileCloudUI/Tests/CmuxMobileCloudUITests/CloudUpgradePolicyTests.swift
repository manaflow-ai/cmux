import Testing
@testable import CmuxMobileCloudUI

struct CloudUpgradePolicyTests {
    @Test("US storefront uses the web pricing route")
    func usStorefrontUsesWeb() {
        #expect(
            CloudUpgradePolicy(storefrontCountryCode: "US", hasInAppBilling: true).route == .web
        )
        #expect(
            CloudUpgradePolicy(storefrontCountryCode: " us ", hasInAppBilling: false).route == .web
        )
    }

    @Test("non-US storefront with billing uses the in-app plans route")
    func nonUSStorefrontUsesInAppBilling() {
        #expect(
            CloudUpgradePolicy(storefrontCountryCode: "GB", hasInAppBilling: true).route == .inApp
        )
        #expect(
            CloudUpgradePolicy(storefrontCountryCode: nil, hasInAppBilling: true).route == .inApp
        )
    }

    @Test("non-US storefront without billing has no purchase route")
    func nonUSStorefrontWithoutBillingIsUnavailable() {
        #expect(
            CloudUpgradePolicy(storefrontCountryCode: "JP", hasInAppBilling: false).route == .unavailable
        )
    }
}

#if os(iOS)
import Foundation
@testable import CmuxMobileAuth
import Testing

/// The always-on simulator (scripts/ios-live) mirrors a person's own Macs, which sign in to the
/// production Stack project: a DEBUG simulator launch with `CMUX_MOBILE_STACK_ENVIRONMENT=production`
/// signs in there, and keeps it for launches the system makes. Nothing else changes.
@Suite struct StackEnvironmentOverrideTests {
    private static let variable = "CMUX_MOBILE_STACK_ENVIRONMENT"

    private func defaults() -> UserDefaults {
        let name = "StackEnvironmentOverrideTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func development(_ env: [String: String], debug: Bool = true, simulator: Bool = true,
                             staging: Bool = false, _ defaults: UserDefaults) -> Bool {
        CmuxMobileAuthModel.usesDevelopmentStack(
            environment: env, isDebug: debug, isSimulator: simulator, stagingStack: staging, defaults: defaults)
    }

    @Test func debugBuildsUseDevelopmentByDefault() {
        #expect(development([:], defaults()))
    }

    @Test func aSimulatorLaunchCanAskForProductionAndKeepsIt() {
        let store = defaults()
        #expect(!development([Self.variable: "production"], store))
        // A launch the system makes carries no variables: still production.
        #expect(!development([:], store))
        // Asking for development (or anything else) clears it.
        #expect(development([Self.variable: "development"], store))
        #expect(development([:], store))
    }

    @Test func deviceAndShippingBuildsNeverReadIt() {
        let store = defaults()
        #expect(development([Self.variable: "production"], simulator: false, store))
        #expect(!development([Self.variable: "development"], debug: false, store))
        #expect(development([Self.variable: "production"], debug: false, staging: true, store))
        #expect(store.string(forKey: CmuxMobileAuthModel.stackEnvironmentOverrideKey) == nil)
    }
}
#endif

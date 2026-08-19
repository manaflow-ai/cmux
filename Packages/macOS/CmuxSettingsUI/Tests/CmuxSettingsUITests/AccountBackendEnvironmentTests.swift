import Testing
@testable import CmuxSettingsUI

/// The package-local backend environment enum mirrors the host's persisted
/// override; these tests pin the contract the host mapping relies on.
@Suite("AccountBackendEnvironment")
struct AccountBackendEnvironmentTests {
    @Test func productionAndStagingAreTheOnlyCasesWithProductionFirst() {
        #expect(AccountBackendEnvironment.allCases == [.production, .staging])
    }

    @Test func rawValuesMatchTheHostOverrideStorageValues() {
        #expect(AccountBackendEnvironment.production.rawValue == "production")
        #expect(AccountBackendEnvironment.staging.rawValue == "staging")
        #expect(AccountBackendEnvironment(rawValue: "production") == .production)
        #expect(AccountBackendEnvironment(rawValue: "staging") == .staging)
    }

    @Test func displayNamesAreNonEmptyAndDistinct() {
        #expect(!AccountBackendEnvironment.production.displayName.isEmpty)
        #expect(!AccountBackendEnvironment.staging.displayName.isEmpty)
        #expect(
            AccountBackendEnvironment.production.displayName
                != AccountBackendEnvironment.staging.displayName
        )
    }
}

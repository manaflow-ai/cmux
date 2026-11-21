import Testing
@testable import CmuxNextBrowser

/// Imported passwords go to the store of the Chromium that runs, under the key it actually uses. When the fork or shim
/// does not take cmux's own keychain item, a Release build runs Chromium on the mock keychain (`CEFRuntime.applyKeychainItem`),
/// whose key is a public constant; a development bundle can run on the real keychain (`CMUX_NEXT_REAL_KEYCHAIN=1`).
/// The bundle identifier alone cannot tell either case.
@Suite struct PasswordImportKeyTests {
    @Test func aReleaseBuildWhoseChromiumFellBackToTheMockKeychainImportsNoPasswords() {
        #expect(PasswordImportKey.storesUnderMockKey(chromiumUsesMockKeychain: true, environment: [:]))
    }

    /// The gate no longer reads the bundle identifier, so this one case covers a Release build on its own keychain item
    /// and a development bundle on the real keychain alike.
    @Test func aBuildOnTheRealKeychainImportsPasswords() {
        #expect(!PasswordImportKey.storesUnderMockKey(chromiumUsesMockKeychain: false, environment: [:]))
    }

    @Test func beforeChromiumStartsNothingIsImported() {
        #expect(PasswordImportKey.storesUnderMockKey(chromiumUsesMockKeychain: nil, environment: [:]))
    }

    #if DEBUG
    @Test func debugBuildsMayImportThrowawayDataUnderTheMockKey() {
        #expect(!PasswordImportKey.storesUnderMockKey(chromiumUsesMockKeychain: true,
                                                      environment: ["CMUX_NEXT_PASSWORD_IMPORT_MOCK_KEY": "throwaway"]))
    }
    #endif
}

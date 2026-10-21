import AppKit
import CmuxNextAccounts
@testable import CmuxNextApp
import CmuxNextCodeRouter
import Testing

/// The DEBUG showcase profile (`--showcase`, `CMUX_NEXT_SHOWCASE=1`) feeds
/// screenshots and recordings. Settings > Accounts there shows the package's
/// fixture sign-ins only: it never reads this Mac's real ones (files in the
/// home folder, the login shell's variables, Keychain items).
@MainActor @Suite(.serialized)
struct AccountsShowcaseDetectionTests {
    @Test func theShowcaseDetectsTheFixtureNotThisMac() async {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"]))
        #expect(services.environment.showcase)
        let found = await services.accounts.detect()
        let fixture = await MockAccountsServices().detect()
        #expect(found == fixture)
    }
}

import Foundation
@testable import CmuxNextApp
import Testing

/// cx-r3q: DEV and NIGHTLY builds crash at an exception's throw site
/// (NSApplicationCrashOnExceptions) instead of letting AppKit catch it and
/// fail later somewhere else; Release and RC keep AppKit's default.
@Suite struct CrashOnExceptionsTests {
    @Test func devAndNightlyCrashOnExceptionsReleaseDoesNot() {
        let key = CrashOnExceptions.key
        #expect(CrashOnExceptions.defaults(bundleID: "com.cmuxterm.app.debug.hmdm2", isDebugBuild: true)[key] as? Bool == true)
        #expect(CrashOnExceptions.defaults(bundleID: "com.cmuxterm.app.nightly", isDebugBuild: false)[key] as? Bool == true)
        #expect(CrashOnExceptions.defaults(bundleID: "com.cmuxterm.app.nightly.nxdog66-v1", isDebugBuild: false)[key] as? Bool == true)
        #expect(CrashOnExceptions.defaults(bundleID: "com.cmuxterm.app", isDebugBuild: false).isEmpty)
        #expect(CrashOnExceptions.defaults(bundleID: "com.cmuxterm.app.rc", isDebugBuild: false).isEmpty)
    }

    @Test func registeringUsesTheVolatileDomainSoAUserSettingWins() throws {
        let name = "crash-on-exceptions-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        CrashOnExceptions.register(in: defaults)
        #expect(defaults.persistentDomain(forName: name)?[CrashOnExceptions.key] == nil, "nothing written to disk")
        #expect(defaults.bool(forKey: CrashOnExceptions.key), "a Debug test build registers it")
        defaults.set(false, forKey: CrashOnExceptions.key)
        #expect(!defaults.bool(forKey: CrashOnExceptions.key), "the user's own value wins")
    }
}

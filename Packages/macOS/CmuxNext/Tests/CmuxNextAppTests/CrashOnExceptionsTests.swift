import Foundation
@testable import CmuxNextApp
import Testing

/// cx-r3q: every cmux-next build crashes at an exception's throw site
/// (NSApplicationCrashOnExceptions) instead of letting AppKit catch it and
/// fail later somewhere else (Release and RC since 2026-10-08).
@Suite struct CrashOnExceptionsTests {
    @Test func everyChannelCrashesOnExceptions() {
        let key = CrashOnExceptions.key
        #expect(CrashOnExceptions.defaults(bundleID: "com.cmuxterm.app.debug.hmdm2", isDebugBuild: true)[key] as? Bool == true)
        #expect(CrashOnExceptions.defaults(bundleID: "com.cmuxterm.app.nightly", isDebugBuild: false)[key] as? Bool == true)
        #expect(CrashOnExceptions.defaults(bundleID: "com.cmuxterm.app.nightly.nxdog66-v1", isDebugBuild: false)[key] as? Bool == true)
        #expect(CrashOnExceptions.defaults(bundleID: "com.cmuxterm.app", isDebugBuild: false)[key] as? Bool == true)
        #expect(CrashOnExceptions.defaults(bundleID: "com.cmuxterm.app.rc", isDebugBuild: false)[key] as? Bool == true)
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

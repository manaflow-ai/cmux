import Foundation
import Testing
@testable import CmuxNextOnboarding

/// Crash program: the System Settings deep links are literals that must parse.
@MainActor @Suite struct OnboardingCrashLiteralTests {
    @Test func systemSettingsLinksParse() {
        #expect(URL.systemSettingsFullDiskAccess.scheme == "x-apple.systempreferences")
        #expect(URL.systemSettingsDefaultBrowser.scheme == "x-apple.systempreferences")
    }
}

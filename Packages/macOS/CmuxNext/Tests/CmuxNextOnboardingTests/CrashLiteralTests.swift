import Foundation
import Testing
@testable import CmuxNextOnboarding

/// Crash program: the System Settings deep link is a literal that must parse.
@MainActor @Suite struct OnboardingCrashLiteralTests {
    @Test func systemSettingsLinksParse() {
        #expect(URL.systemSettingsFullDiskAccess.scheme == "x-apple.systempreferences")
    }
}

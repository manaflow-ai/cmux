import CmuxNextBrowserImport
import Testing
@testable import CmuxNextOnboarding

/// The password import's finished line and the consent screen's Keychain
/// paragraph: a differing saved password is reported on its own, never also
/// as skipped, and Firefox (whose key is in its profile) gets its own text.
@Suite struct PasswordImportStringsTests {
    private func report(neverSaved: Int = 0, duplicate: Int = 0, conflict: Int = 0, rejected: Int = 0) -> PasswordImportReport {
        var report = PasswordImportReport()
        report.skipped.neverSaved = neverSaved
        report.store.duplicate = duplicate
        report.store.conflict = conflict
        report.store.rejected = rejected
        return report
    }

    @Test func aConflictIsCountedOnceNotAlsoAsSkipped() {
        let mixed = report(neverSaved: 3, duplicate: 1, conflict: 2)
        #expect(mixed.notImported == 6)
        #expect(mixed.conflicts == 2)
        #expect(mixed.notImportedOtherThanConflicts == 4)
        #expect(OnboardingStrings.passwordsSummary([mixed, report(rejected: 1)])
            == "Passwords skipped: 5 Already saved with a different password: 2. cmux kept the saved password.")
    }

    @Test func eachSentenceShowsOnlyWhenItsCountIsAboveZero() {
        #expect(OnboardingStrings.passwordsSummary([report(duplicate: 9)]) == "Passwords skipped: 9")
        #expect(OnboardingStrings.passwordsSummary([report(conflict: 1)])
            == "Already saved with a different password: 1. cmux kept the saved password.")
        #expect(OnboardingStrings.passwordsSummary([report()]).isEmpty)
        #expect(OnboardingStrings.passwordsSummary([]).isEmpty)
    }

    @Test func theConsentTextFollowsTheBrowsersSelected() {
        let quote: ([String]) -> String = { $0.joined(separator: " and ") }
        let chromium = OnboardingStrings.passwordsKeychain("Chrome Safe Storage")
        #expect(OnboardingStrings.passwordsConsent(keychainItems: ["Chrome Safe Storage"], includesFirefox: false, quote: quote) == chromium)
        #expect(OnboardingStrings.passwordsConsent(keychainItems: ["Chrome Safe Storage"], includesFirefox: true, quote: quote)
            == chromium + " If a Firefox profile has a primary password, cmux asks for it once and does not keep it.")
        #expect(OnboardingStrings.passwordsConsent(keychainItems: [], includesFirefox: true, quote: quote)
            == "Import asks you to confirm with Touch ID or your password. Firefox keeps its key in the profile, so macOS asks for no Keychain item. If a Firefox profile has a primary password, cmux asks for it once and does not keep it.")
    }
}

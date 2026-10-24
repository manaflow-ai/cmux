@testable import CmuxNextApp
@testable import CmuxNextCookieImport
import CmuxNextDaemonService
import CmuxNextRemoteBrowser
@testable import CmuxNextSettingsWindow
import Foundation
import Testing

/// Sentences that hold a number agree with it in every language: a plural form per count, a label before a count
/// where no form can carry it, and seconds written by Foundation in the sentence's language.
@MainActor
struct CountSentenceTests {
    static let latin = Locale(identifier: "en_US@numbers=latn")

    /// CLDR's abbreviated seconds in `language`, the form a sentence must carry.
    static func seconds(_ count: Int, _ language: String) -> String {
        Duration.seconds(count).formatted(.units(allowed: [.seconds], width: .abbreviated)
            .locale(Locale(identifier: "\(language)_US@numbers=latn")))
    }

    @Test func searchMatchesAgreeWithTheCount() {
        let matches = { (count: Int, language: String) in
            GlobalSearchStrings.matches(count, preferredLocalizations: [language], locale: Self.latin)
        }
        #expect(matches(2, "en") == "2 matches")
        #expect(matches(2, "ar") == "مطابقتان (2)")
        #expect(matches(3, "ar") == "3 مطابقات")
        #expect(matches(11, "ar") == "11 مطابقة")
        #expect(matches(2, "fr") == "2 résultats")
    }

    @Test func savedPasswordsAgreeWithTheCount() {
        let passwords = { (count: Int, language: String) in
            PasswordStrings.passwordCount(count, preferredLocalizations: [language], locale: Self.latin)
        }
        #expect(passwords(2, "en") == "2 saved passwords")
        #expect(passwords(2, "ar") == "كلمتا مرور محفوظتان (2)")
        #expect(passwords(2, "ru") == "2 сохранённых пароля")
        #expect(passwords(5, "ru") == "5 сохранённых паролей")
        #expect(passwords(2, "de") == "2 gespeicherte Passwörter")
    }

    @Test func aScreenIndexRefusalCountsScreens() {
        #expect(RefusalStrings.screenCount(1, preferredLocalizations: ["en"], locale: Self.latin) == "the workspace has 1 screen")
        #expect(RefusalStrings.screenCount(2, preferredLocalizations: ["en"], locale: Self.latin) == "the workspace has 2 screens")
    }

    @Test func debugSettingsCountsTunablesAfterALabel() {
        #expect(DebugSettingsStrings.count(1, preferredLocalizations: ["en"], locale: Self.latin) == "Tunables: 1")
    }

    @Test func cookieImportWritesItsDeadlineAndCount() {
        #expect(CookieImportStrings.deadline(30, preferredLocalizations: ["en"], locale: Self.latin) == "Denied automatically after 30 sec")
        let arabic = CookieImportStrings.deadline(3, preferredLocalizations: ["ar"], locale: Self.latin)
        #expect(arabic.contains(Self.seconds(3, "ar")) && !arabic.contains("ثانية"), "\(arabic)")
        #expect(CookieImportStrings.done(count: 1, browser: "Chrome", preferredLocalizations: ["en"], locale: Self.latin)
            == "Cookies imported from Chrome: 1.")
    }

    #if DEBUG
    @Test func aLocalHostTimeoutWritesTheSecondsInItsOwnLanguage() {
        let log = URL(fileURLWithPath: "/tmp/host.log")
        let failure = { (seconds: Int, language: String) in
            RemoteBrowserStrings.hostFailure(LocalRemoteBrowserHost.Failure.timedOut(seconds: seconds, log: log),
                                             preferredLocalizations: [language], locale: Self.latin)
        }
        #expect(failure(60, "en") == "The host did not get ready within 60 sec and was stopped. Its log is at /tmp/host.log.")
        let arabic = failure(3, "ar")
        #expect(arabic.contains(Self.seconds(3, "ar")) && !arabic.contains("ثانية"), "\(arabic)")
    }
    #endif
}

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

    /// `text` as a `%@` argument reads inside a sentence that holds right-to-left text: Foundation's
    /// `String(format:locale:)` writes it between U+2068 FIRST STRONG ISOLATE and U+2069 POP DIRECTIONAL ISOLATE
    /// (see `Bundle.localizedString(forKey:value:table:arguments:preferredLocalizations:locale:)`).
    static func isolated(_ text: String) -> String { "\u{2068}\(text)\u{2069}" }

    /// Whether `text` holds `part` exactly: a literal search, so a Latin "3" never matches an Arabic-Indic "٣" (the
    /// default `contains` on a bridged `String(format:)` result is not literal).
    static func holds(_ text: String, _ part: String) -> Bool { text.range(of: part, options: .literal) != nil }

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
        #expect(Self.holds(arabic, Self.isolated(Self.seconds(3, "ar"))) && !arabic.contains("ثانية"), "\(arabic)")
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
        #expect(Self.holds(arabic, Self.isolated(Self.seconds(3, "ar"))) && !arabic.contains("ثانية"), "\(arabic)")
    }
    #endif
}

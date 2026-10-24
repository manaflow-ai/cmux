@testable import CmuxNextUpdater
import Foundation
import Testing

/// The update card's counts and waits: a plural form per count, and minutes and seconds written by Foundation in
/// the notice's language, so no translation carries a unit or a noun after a number.
@MainActor
struct UpdaterCountTextTests {
    static let latin = Locale(identifier: "en_US@numbers=latn")

    /// `text` as a `%@` argument reads inside a sentence that holds right-to-left text: Foundation's
    /// `String(format:locale:)` writes it between U+2068 FIRST STRONG ISOLATE and U+2069 POP DIRECTIONAL ISOLATE
    /// (see `Bundle.localizedString(forKey:value:table:arguments:preferredLocalizations:locale:)`).
    static func isolated(_ text: String) -> String { "\u{2068}\(text)\u{2069}" }

    /// Whether `text` holds `part` exactly: a literal search, so a Latin "3" never matches an Arabic-Indic "٣" (the
    /// default `contains` on a bridged `String(format:)` result is not literal).
    static func holds(_ text: String, _ part: String) -> Bool { text.range(of: part, options: .literal) != nil }

    /// CLDR's abbreviated `units` for `duration` in `language`, the form a notice must carry.
    static func short(_ duration: Duration, _ units: Set<Duration.UnitsFormatStyle.Unit>, _ language: String) -> String {
        duration.formatted(.units(allowed: units, width: .abbreviated).locale(Locale(identifier: "\(language)_US@numbers=latn")))
    }

    @Test func theStalledNoticeWritesTheMinutesInItsOwnLanguage() {
        #expect(UpdaterStrings.installStalledDetail(minutes: 4, preferredLocalizations: ["en"], locale: Self.latin)
            == "cmux waited 4 min for the installer. Your windows are back. Details shows the update log.")
        for language in ["ar", "ja", "ru"] {
            let detail = UpdaterStrings.installStalledDetail(minutes: 4, preferredLocalizations: [language], locale: Self.latin)
            #expect(Self.holds(detail, Self.short(.seconds(240), [.minutes], language)), "\(language): \(detail)")
            #expect(!detail.contains("min"), "\(language): an English unit: \(detail)")
        }
        let arabic = UpdaterStrings.installStalledDetail(minutes: 11, preferredLocalizations: ["ar"], locale: Self.latin)
        #expect(Self.holds(arabic, Self.isolated(Self.short(.seconds(660), [.minutes], "ar"))), "\(arabic)")
        #expect(!arabic.contains("دقيقة") && !arabic.contains("دقائق"), "a minute noun after the count: \(arabic)")
    }

    @Test func theCheckingNoticeWritesTheSecondsInItsOwnLanguage() {
        #expect(UpdaterStrings.checkingNewVersion(seconds: 5, preferredLocalizations: ["en"], locale: Self.latin)
            == "The installer checks the new version (5 sec). cmux relaunches when it is done. Your terminals and agents keep running.")
        let arabic = UpdaterStrings.checkingNewVersion(seconds: 3, preferredLocalizations: ["ar"], locale: Self.latin)
        #expect(Self.holds(arabic, "(" + Self.isolated(Self.short(.seconds(3), [.seconds], "ar")) + ")"), "\(arabic)")
    }

    @Test func moreChangesAgreesWithTheCount() {
        let more = { (count: Int, language: String) in UpdaterStrings.moreChanges(count, preferredLocalizations: [language], locale: Self.latin) }
        #expect(more(1, "en") == "1 more change")
        #expect(more(2, "en") == "2 more changes")
        #expect(more(2, "ar") == "تغييران آخران (2)")
        #expect(more(3, "ar") == "3 تغييرات أخرى")
        #expect(more(11, "ar") == "11 تغييرًا آخر")
        #expect(more(2, "pl") == "Jeszcze 2 zmiany")
        #expect(more(5, "pl") == "Jeszcze 5 zmian")
    }
}

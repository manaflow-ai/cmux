@testable import CmuxNextUpdater
import Foundation
import Testing

/// The update card's counts and waits: a plural form per count, and minutes and seconds written by Foundation in
/// the notice's language, so no translation carries a unit or a noun after a number.
@MainActor
struct UpdaterCountTextTests {
    static let latin = Locale(identifier: "en_US@numbers=latn")

    /// CLDR's abbreviated `units` for `duration` in `language`, the form a notice must carry.
    static func short(_ duration: Duration, _ units: Set<Duration.UnitsFormatStyle.Unit>, _ language: String) -> String {
        duration.formatted(.units(allowed: units, width: .abbreviated).locale(Locale(identifier: "\(language)_US@numbers=latn")))
    }

    @Test func theStalledNoticeWritesTheMinutesInItsOwnLanguage() {
        #expect(UpdaterStrings.installStalledDetail(minutes: 4, preferredLocalizations: ["en"], locale: Self.latin)
            == "cmux waited 4 min for the installer. Your windows are back. Details shows the update log.")
        for language in ["ar", "ja", "ru"] {
            let detail = UpdaterStrings.installStalledDetail(minutes: 4, preferredLocalizations: [language], locale: Self.latin)
            #expect(detail.contains(Self.short(.seconds(240), [.minutes], language)), "\(language): \(detail)")
            #expect(!detail.contains("min"), "\(language): an English unit: \(detail)")
        }
        let arabic = UpdaterStrings.installStalledDetail(minutes: 11, preferredLocalizations: ["ar"], locale: Self.latin)
        #expect(!arabic.contains("دقيقة") && !arabic.contains("دقائق"), "a minute noun after the count: \(arabic)")
    }

    @Test func theCheckingNoticeWritesTheSecondsInItsOwnLanguage() {
        #expect(UpdaterStrings.checkingNewVersion(seconds: 5, preferredLocalizations: ["en"], locale: Self.latin)
            == "The installer checks the new version (5 sec). cmux relaunches when it is done. Your terminals and agents keep running.")
        let arabic = UpdaterStrings.checkingNewVersion(seconds: 3, preferredLocalizations: ["ar"], locale: Self.latin)
        #expect(arabic.contains("(" + Self.short(.seconds(3), [.seconds], "ar") + ")"), "\(arabic)")
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

@testable import CmuxNextApp
import Foundation
import Testing

/// Home's merge notice is a transcript row the user reads, so it ships in
/// every app language of the built bundle, and each translation differs from
/// English.
struct HomeChiefNoticeLocalizationTests {
    private static let languages = ["en", "ar", "bs", "da", "de", "es", "fr", "it", "ja", "km", "ko", "nb",
                                    "pl", "pt-BR", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"]
    private static let key = "home.chief.mergeBlocked"

    /// The compiled `Home.strings` of one localization in the app bundle.
    private static func compiled(_ language: String) throws -> [String: String] {
        let lproj = try #require(Bundle.module.path(forResource: language, ofType: "lproj"), "no \(language).lproj")
        let url = URL(fileURLWithPath: lproj).appending(path: "Home.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String], "no \(language) Home.strings")
    }

    @Test func theEnglishNoticeIsTheBlockedMigrationsNotice() throws {
        let english = try #require(try Self.compiled("en")[Self.key])
        #expect(english == "Quit older cmux DEV builds to merge Chief history")
        #expect(ChiefMigration.notice(for: .blocked(["hmchief4"])) == HomeStrings.chiefMergeBlocked)
    }

    @Test(arguments: languages.dropFirst())
    func theNoticeShipsTranslated(_ language: String) throws {
        let english = try #require(try Self.compiled("en")[Self.key])
        let translated = try #require(try Self.compiled(language)[Self.key], "no \(language) \(Self.key)")
        #expect(!translated.isEmpty)
        #expect(translated != english, "\(language) is English")
    }
}

@testable import CmuxNextApp
import Foundation
import Testing

/// The Find Work page's "N unread" accessory picks each language's plural form for the count
/// (French "1 non lu", "2 non lus"; Arabic's own one and two forms).
///
/// Each case reads one language's table from CmuxNextApp's bundle (`<lang>.lproj`), so it does not
/// depend on the test runner's language. Before the plural fix the key had one flat value per
/// language, so French said "1 non lus" and Arabic used one form for 1, 2 and 11.
@Suite struct FindWorkUnreadPluralsTests {
    /// One language's table in CmuxNextApp's catalogs and its locale.
    func table(_ language: String) throws -> (bundle: Bundle, locale: Locale) {
        let bundle = FindWorkStrings.bundle
        let table = try #require(bundle.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)),
                                 "\(bundle.bundlePath) has no \(language).lproj")
        return (table, Locale(identifier: language))
    }

    /// English keeps "unread" for every count.
    @Test(arguments: [(1, "1 unread"), (2, "2 unread")])
    func theEnglishAccessory(count: Int, expected: String) throws {
        let english = try table("en")
        #expect(FindWorkStrings.unread(count, bundle: english.bundle, locale: english.locale) == expected)
    }

    /// French's "one" form is singular: "1 non lu", but "2 non lus".
    @Test(arguments: [(1, "1 non lu"), (2, "2 non lus")])
    func theFrenchAccessoryPicksItsForm(count: Int, expected: String) throws {
        let french = try table("fr")
        #expect(FindWorkStrings.unread(count, bundle: french.bundle, locale: french.locale) == expected)
    }

    /// Arabic names one and two with their own words, not a number before one form. The check
    /// reads the words only, because the digits Arabic shows differ between macOS majors.
    @Test func arabicHasItsOwnOneAndTwo() throws {
        let arabic = try table("ar")
        let one = FindWorkStrings.unread(1, bundle: arabic.bundle, locale: arabic.locale)
        let two = FindWorkStrings.unread(2, bundle: arabic.bundle, locale: arabic.locale)
        #expect(one.hasPrefix("علامة تبويب واحدة"), "Arabic unread for 1 is \(one)")
        #expect(two.hasPrefix("علامتا تبويب"), "Arabic unread for 2 is \(two)")
    }
}

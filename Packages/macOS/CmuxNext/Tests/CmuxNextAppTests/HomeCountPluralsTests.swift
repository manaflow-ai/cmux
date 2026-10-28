@testable import CmuxNextHome
import Foundation
import Testing

/// Home's two counted strings pick each language's plural form for the count: a large group's
/// members header ("1 member", "2 members") and the unread part of a row's VoiceOver label
/// (French "1 non lu", "2 non lus"; Arabic's own one and two forms).
///
/// Each case reads one language's table from CmuxNextHome's bundle (`<lang>.lproj`), so it does
/// not depend on the test runner's language. Before the plural fix the members header said
/// "1 members" (the helper passed a preformatted String through "%@", which cannot pick a form),
/// and both keys had one flat value per language ("1 non lus" in French).
@Suite struct HomeCountPluralsTests {
    /// One language's table in CmuxNextHome's catalog and its locale.
    func table(_ language: String) throws -> (bundle: Bundle, locale: Locale) {
        let bundle = HomeConversationStrings.bundle
        let table = try #require(bundle.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)),
                                 "\(bundle.bundlePath) has no \(language).lproj")
        return (table, Locale(identifier: language))
    }

    /// The members header in English, through the helper the group info sheet uses.
    @Test(arguments: [(1, "1 member"), (2, "2 members"), (5000, "5,000 members")])
    func theMembersHeaderPicksTheEnglishForm(count: Int, expected: String) throws {
        let english = try table("en")
        #expect(HomeConversationStrings.infoMemberCount(count, bundle: english.bundle, locale: english.locale) == expected)
    }

    /// German has its own singular, and the count keeps the locale's grouping.
    @Test(arguments: [(1, "1 Mitglied"), (2, "2 Mitglieder"), (5000, "5.000 Mitglieder")])
    func theMembersHeaderPicksTheGermanForm(count: Int, expected: String) throws {
        let german = try table("de")
        #expect(HomeConversationStrings.infoMemberCount(count, bundle: german.bundle, locale: german.locale) == expected)
    }

    /// French's "one" form is singular: "1 non lu", but "2 non lus".
    @Test(arguments: [(1, "1 non lu"), (2, "2 non lus")])
    func theUnreadLabelPicksTheFrenchForm(count: Int, expected: String) throws {
        let french = try table("fr")
        #expect(HomeConversationStrings.unread(count, bundle: french.bundle, locale: french.locale) == expected)
    }

    /// Arabic names one and two with their own words, not a number before one noun form. The
    /// check reads the words only, because the digits Arabic shows differ between macOS majors.
    @Test func arabicHasItsOwnOneAndTwo() throws {
        let arabic = try table("ar")
        let unreadOne = HomeConversationStrings.unread(1, bundle: arabic.bundle, locale: arabic.locale)
        let unreadTwo = HomeConversationStrings.unread(2, bundle: arabic.bundle, locale: arabic.locale)
        #expect(unreadOne.hasPrefix("رسالة واحدة"), "Arabic unread for 1 is \(unreadOne)")
        #expect(unreadTwo.hasPrefix("رسالتان"), "Arabic unread for 2 is \(unreadTwo)")
        let membersOne = HomeConversationStrings.infoMemberCount(1, bundle: arabic.bundle, locale: arabic.locale)
        let membersTwo = HomeConversationStrings.infoMemberCount(2, bundle: arabic.bundle, locale: arabic.locale)
        #expect(membersOne.hasPrefix("عضو واحد"), "Arabic members for 1 is \(membersOne)")
        #expect(membersTwo.hasPrefix("عضوان"), "Arabic members for 2 is \(membersTwo)")
    }

    /// The group info sheet's header, through HomeGroupInfo's own path in one fixed language:
    /// the plain "Members" without a count, else the counted form.
    @Test(arguments: [(nil, "Members"), (1, "1 member"), (2, "2 members")] as [(Int?, String)])
    func theSheetsHeaderPicksTheEnglishForm(count: Int?, expected: String) throws {
        let english = try table("en")
        #expect(HomeGroupInfo.membersHeader(count: count, bundle: english.bundle, locale: english.locale) == expected)
    }

    /// The sheet's header in German: "Mitglieder" without a count, "1 Mitglied" for one.
    @Test(arguments: [(nil, "Mitglieder"), (1, "1 Mitglied")] as [(Int?, String)])
    func theSheetsHeaderPicksTheGermanForm(count: Int?, expected: String) throws {
        let german = try table("de")
        #expect(HomeGroupInfo.membersHeader(count: count, bundle: german.bundle, locale: german.locale) == expected)
    }
}

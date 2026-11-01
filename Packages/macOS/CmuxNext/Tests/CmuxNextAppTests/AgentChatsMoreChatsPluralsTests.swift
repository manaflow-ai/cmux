@testable import CmuxNextAgentLanes
import Foundation
import Testing

/// The palette chats page's "N more chats" row picks each language's plural form for the count
/// (lead, review of #28090: a user-visible count string must show the right plural form, and its
/// test must read the shown text, not compare the function with itself).
///
/// Each case reads one language's table from CmuxNextAgentLanes' bundle (`<lang>.lproj`), so it does not
/// depend on the test runner's language.
@Suite struct AgentChatsMoreChatsPluralsTests {
    func table(_ language: String) throws -> (bundle: Bundle, locale: Locale) {
        let bundle = AgentChatsPaletteStrings.bundle
        let table = try #require(bundle.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)),
                                 "\(bundle.bundlePath) has no \(language).lproj")
        return (table, Locale(identifier: language))
    }

    @Test(arguments: [(1, "1 more chat. Type to search."), (2, "2 more chats. Type to search."),
                      (2_999, "2,999 more chats. Type to search.")])
    func theEnglishRow(count: Int, expected: String) throws {
        let english = try table("en")
        #expect(AgentChatsPaletteStrings.moreChats(count, bundle: english.bundle, locale: english.locale) == expected)
    }

    /// French's "one" form is singular: "1 autre chat", but "2 autres chats".
    @Test(arguments: [(1, "1 autre chat. Tapez pour rechercher."), (2, "2 autres chats. Tapez pour rechercher.")])
    func theFrenchRowPicksItsForm(count: Int, expected: String) throws {
        let french = try table("fr")
        #expect(AgentChatsPaletteStrings.moreChats(count, bundle: french.bundle, locale: french.locale) == expected)
    }

    /// Russian has its own one, few and many forms.
    @Test(arguments: [(1, "Ещё 1 чат. Начните вводить для поиска."), (3, "Ещё 3 чата. Начните вводить для поиска."),
                      (5, "Ещё 5 чатов. Начните вводить для поиска.")])
    func theRussianRowPicksItsForm(count: Int, expected: String) throws {
        let russian = try table("ru")
        #expect(AgentChatsPaletteStrings.moreChats(count, bundle: russian.bundle, locale: russian.locale) == expected)
    }
}

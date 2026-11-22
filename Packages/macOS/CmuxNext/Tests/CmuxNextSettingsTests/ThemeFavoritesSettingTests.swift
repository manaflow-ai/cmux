import Foundation
@testable import CmuxNextSettings
import Testing

/// `appearance.favoriteThemes` and `appearance.rotateFavoriteThemes` (``ThemeFavoritesSetting``): the
/// starred list as the pickers write it, and the theme a launch turns to.
@Suite struct ThemeFavoritesSettingTests {
    private let setting = ThemeFavoritesSetting()

    private func root(theme: String? = nil, favorites: [JSONValue], rotate: String?) -> JSONValue {
        var appearance: [String: JSONValue] = ["favoriteThemes": .array(favorites)]
        if let theme { appearance["theme"] = .string(theme) }
        if let rotate { appearance["rotateFavoriteThemes"] = .string(rotate) }
        return .object(["appearance": .object(appearance)])
    }

    @Test func favoritesKeepTheirOrderAndDropRepeatsPairsAndNonStrings() {
        let parsed = setting.favorites(root(favorites: [.string("Nord"), .string("Dracula"), .string("Nord"), .number(1),
                                                         .string("light:A,dark:B"), .string(" "), .string("Rose Pine")],
                                            rotate: nil))
        #expect(parsed == ["Nord", "Dracula", "Rose Pine"])
        #expect(setting.favorites(.object([:])).isEmpty)
    }

    @Test func nextWrapsAndStartsAtTheFirstForAThemeThatIsNotStarred() {
        let favorites = ["Nord", "Dracula", "Rose Pine"]
        #expect(ThemeFavoritesSetting.next(after: "Nord", in: favorites) == "Dracula")
        #expect(ThemeFavoritesSetting.next(after: "Rose Pine", in: favorites) == "Nord")
        #expect(ThemeFavoritesSetting.next(after: "Tokyo Night", in: favorites) == "Nord")
        #expect(ThemeFavoritesSetting.next(after: nil, in: favorites) == "Nord")
        #expect(ThemeFavoritesSetting.next(after: "Nord", in: ["Nord"]) == nil)
        #expect(ThemeFavoritesSetting.next(after: nil, in: []) == nil)
    }

    @Test func rotationIsOffUnlessSetAndDailyTurnsOncePerDay() {
        let starred: [JSONValue] = [.string("Nord"), .string("Dracula")]
        #expect(setting.rotated(root(theme: "Nord", favorites: starred, rotate: nil), today: "2026-10-20", lastDay: nil) == nil)
        #expect(setting.rotated(root(theme: "Nord", favorites: starred, rotate: "bogus"), today: "2026-10-20", lastDay: nil) == nil)
        let launch = root(theme: "Nord", favorites: starred, rotate: "launch")
        #expect(setting.rotated(launch, today: "2026-10-20", lastDay: "2026-10-20") == "Dracula")
        let daily = root(theme: "Dracula", favorites: starred, rotate: "daily")
        #expect(setting.rotated(daily, today: "2026-10-20", lastDay: "2026-10-20") == nil)
        #expect(setting.rotated(daily, today: "2026-10-21", lastDay: "2026-10-20") == "Nord")
        #expect(setting.rotated(daily, today: "2026-10-21", lastDay: nil) == "Nord")
    }

    @Test func aLightAndDarkPairIsLeftAlone() {
        let pair = root(theme: "light:Rose Pine Dawn,dark:Rose Pine", favorites: [.string("Nord"), .string("Dracula")], rotate: "launch")
        #expect(setting.rotated(pair, today: "2026-10-20", lastDay: nil) == nil)
        for spec in ["light:Nord,dark:Nord", "dark:Nord"] {
            let same = root(theme: spec, favorites: [.string("Nord"), .string("Dracula")], rotate: "launch")
            #expect(setting.rotated(same, today: "2026-10-20", lastDay: nil) == nil)
        }
    }

    @Test func dayIsTheLocalCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        #expect(ThemeFavoritesSetting.day(Date(timeIntervalSince1970: 1_792_454_400), calendar: calendar) == "2026-10-20")
    }
}

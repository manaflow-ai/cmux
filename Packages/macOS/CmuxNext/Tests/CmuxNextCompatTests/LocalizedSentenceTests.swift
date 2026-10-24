import CmuxNextCompat
import Foundation
import Testing

/// `Bundle.localizedString(forKey:value:table:arguments:preferredLocalizations:locale:)`, the one path for a
/// localized sentence that holds a number, against a string table written to a temporary directory: a count picks
/// the table's plural rule, a duration is written in the sentence's language with the person's numbering system,
/// and a translation that does not take the arguments is never passed to `String(format:)`.
struct LocalizedSentenceTests {
    /// A bundle directory with `en` and `ar` tables: a plural rule for `days` (stringsdict) and plain sentences.
    private final class Fixture {
        let directory: URL
        let bundle: Bundle

        init(english: [String: String], arabic: [String: String], plurals: [String: [String: [String: String]]]) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalizedSentenceTests-\(UUID().uuidString)")
            for (language, strings) in [("en", english), ("ar", arabic)] {
                let folder = directory.appendingPathComponent("\(language).lproj")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let table = strings.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
                try Data(table.utf8).write(to: folder.appendingPathComponent("Localizable.strings"))
                var rules: [String: Any] = [:]
                for (key, forms) in plurals {
                    guard let form = forms[language] else { continue }
                    var rule: [String: Any] = ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld"]
                    for (category, text) in form { rule[category] = text }
                    rules[key] = ["NSStringLocalizedFormatKey": "%#@count@", "count": rule]
                }
                let plist = try PropertyListSerialization.data(fromPropertyList: rules, format: .xml, options: 0)
                try plist.write(to: folder.appendingPathComponent("Localizable.stringsdict"))
            }
            bundle = try #require(Bundle(path: directory.path))
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private static let latin = Locale(identifier: "en_US@numbers=latn")

    private static func days() throws -> Fixture {
        try Fixture(english: [:], arabic: [:], plurals: ["days": [
            "en": ["one": "%lld day old", "other": "%lld days old"],
            "ar": ["zero": "عمرها %lld يوم", "one": "عمرها يوم واحد", "two": "عمرها يومان", "few": "عمرها %lld أيام",
                   "many": "عمرها %lld يومًا", "other": "عمرها %lld يوم"],
        ]])
    }

    @Test(arguments: [(1, "عمرها يوم واحد"), (2, "عمرها يومان"), (3, "عمرها 3 أيام"), (11, "عمرها 11 يومًا"), (100, "عمرها 100 يوم")])
    func aCountPicksTheArabicPluralForm(count: Int, expected: String) throws {
        let fixture = try Self.days()
        #expect(fixture.bundle.localizedString(forKey: "days", value: "%lld days old", table: nil, arguments: [.count(count)],
                                               preferredLocalizations: ["ar"], locale: Self.latin) == expected)
    }

    @Test func aCountPicksTheEnglishPluralForm() throws {
        let fixture = try Self.days()
        let english = { (count: Int) in
            fixture.bundle.localizedString(forKey: "days", value: "%lld days old", table: nil, arguments: [.count(count)],
                                           preferredLocalizations: ["en"], locale: Self.latin)
        }
        #expect(english(1) == "1 day old")
        #expect(english(30) == "30 days old")
    }

    /// A translation with a second `%@`, or a 32-bit `%d` for a count, would read past or misread the arguments.
    @Test(arguments: [("waited %@ and %@", LocalizedArgument.text("5 min")), ("انتظر %d", LocalizedArgument.count(5))])
    func aTranslationThatDoesNotTakeTheArgumentsFallsBackToEnglish(arabic: String, argument: LocalizedArgument) throws {
        let fixture = try Fixture(english: [:], arabic: ["waited": arabic], plurals: [:])
        let english = argument.isText ? "waited %@" : "waited %lld"
        #expect(fixture.bundle.localizedString(forKey: "waited", value: english, table: nil, arguments: [argument],
                                               preferredLocalizations: ["ar"], locale: Self.latin) == "waited 5" + (argument.isText ? " min" : ""))
    }

    /// The unit takes the sentence's language; the digits keep the person's numbering system.
    @Test func aDurationKeepsTheNumberingSystemOfTheLocale() throws {
        let fixture = try Fixture(english: ["after": "after %@"], arabic: ["after": "بعد %@"], plurals: [:])
        let arabicDigits = fixture.bundle.localizedString(forKey: "after", value: "after %@", table: nil,
                                                          arguments: [.duration(.seconds(300), units: [.minutes])], preferredLocalizations: ["en"],
                                                          locale: Locale(identifier: "en_US@numbers=arab"))
        #expect(arabicDigits == "after ٥ min")
        let latinDigits = fixture.bundle.localizedString(forKey: "after", value: "after %@", table: nil,
                                                         arguments: [.duration(.seconds(300), units: [.minutes])], preferredLocalizations: ["ar"],
                                                         locale: Locale(identifier: "ar_AE@numbers=latn"))
        #expect(latinDigits.hasPrefix("بعد 5"), "\(latinDigits)")
        #expect(!latinDigits.contains("٥") && !latinDigits.contains("min"), "\(latinDigits)")
    }

    /// A language the bundle has no table for reads the English sentence with the English unit.
    @Test func anUnsupportedLanguageReadsAllEnglish() throws {
        let fixture = try Fixture(english: ["after": "after %@"], arabic: ["after": "بعد %@"], plurals: [:])
        #expect(fixture.bundle.localizedString(forKey: "after", value: "after %@", table: nil,
                                               arguments: [.duration(.seconds(120), units: [.minutes])], preferredLocalizations: ["he"],
                                               locale: Self.latin) == "after 2 min")
        #expect(fixture.bundle.localizedDuration(.milliseconds(12), units: [.milliseconds], preferredLocalizations: ["he"],
                                                 locale: Self.latin) == "12 ms")
    }
}

private extension LocalizedArgument {
    var isText: Bool {
        if case .text = self { return true }
        return false
    }
}

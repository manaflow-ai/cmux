@testable import CmuxNextControl
import Foundation
import Testing

/// Control-socket errors reach users through the CLI, so every key ships in
/// every language of the compiled module bundle with English's placeholders,
/// and a translated message differs from English.
struct ControlLocalizationTests {
    private static let languages = ["en", "ar", "bs", "da", "de", "es", "fr", "it", "ja", "km", "ko", "nb",
                                    "pl", "pt-BR", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"]

    /// Read the compiled string table. SwiftPM's test bundle on Xcode 26 may
    /// retain the processed catalog as `Localizable.xcstrings` instead of
    /// materializing `lproj` directories; inspect that built resource in that
    /// case so the test still verifies every shipped localization.
    private static func compiled(_ language: String) throws -> [String: String] {
        if let lproj = ControlStrings.bundle.path(forResource: language, ofType: "lproj") {
            let url = URL(fileURLWithPath: lproj).appending(path: "Localizable.strings")
            return try #require(NSDictionary(contentsOf: url) as? [String: String], "no \(language) Localizable.strings")
        }

        let url = try #require(ControlStrings.bundle.url(forResource: "Localizable", withExtension: "xcstrings"),
                                "no localization resource for \(language)")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        var values: [String: String] = [:]
        for (key, rawEntry) in strings {
            let entry = try #require(rawEntry as? [String: Any], "invalid catalog entry \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any], "no localizations for \(key)")
            let localization = try #require(localizations[language] as? [String: Any], "no \(language) value for \(key)")
            let unit = try #require(localization["stringUnit"] as? [String: Any], "no \(language) string unit for \(key)")
            values[key] = try #require(unit["value"] as? String, "no \(language) text for \(key)")
        }
        return values
    }

    @Test(arguments: languages.dropFirst())
    func everyKeyShipsWithEnglishPlaceholders(_ language: String) throws {
        let english = try Self.compiled("en")
        let translated = try Self.compiled(language)
        #expect(english.count > 100)
        #expect(Set(english.keys) == Set(translated.keys),
                "\(language): \(Set(english.keys).symmetricDifference(translated.keys).sorted())")
        for (key, value) in english {
            let other = try #require(translated[key])
            #expect(Self.placeholders(value) == Self.placeholders(other), "\(language) \(key) placeholders differ")
        }
        #expect(translated["control.error.unsupported"] != english["control.error.unsupported"])
    }

    @Test func unsupportedReasonsAndErrorsFormatArguments() {
        #expect(ControlError.busy(pending: 3, limit: 2).message == "cmux is busy (3 queued requests, limit 2); retry later")
    }

    /// Format specifiers by argument, ignoring positional prefixes (`%1$@` == `%@`).
    private static func placeholders(_ text: String) -> [String] {
        text.matches(of: /%(?:\d+\$)?(@|lld|d)/).map { String($0.output.1) }.sorted()
    }
}

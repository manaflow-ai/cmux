@testable import CmuxNextControl
import Foundation
import Testing

/// Control-socket errors reach users through the CLI, so every key ships in
/// every language of the compiled module bundle with English's placeholders,
/// and a translated message differs from English.
struct ControlLocalizationTests {
    private static let languages = ["en", "ar", "bs", "da", "de", "es", "fr", "it", "ja", "km", "ko", "nb",
                                    "pl", "pt-BR", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"]

    /// The compiled `Localizable.strings` of one localization in the module bundle.
    private static func compiled(_ language: String) throws -> [String: String] {
        let lproj = try #require(ControlStrings.bundle.path(forResource: language, ofType: "lproj"), "no \(language).lproj")
        let url = URL(fileURLWithPath: lproj).appending(path: "Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String], "no \(language) Localizable.strings")
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

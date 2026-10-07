@testable import CmuxNextApp
import CmuxNextLayout
import Foundation
import Testing

/// Refusal reasons reach users through the CLI and logs, so every key ships
/// in English and Japanese (checked in the built bundle) and format
/// arguments are substituted.
struct RefusalLocalizationTests {
    /// The compiled `<table>.strings` of one localization in the app bundle.
    private static func compiled(_ table: String, _ language: String) throws -> [String: String] {
        let lproj = try #require(Bundle.module.path(forResource: language, ofType: "lproj"), "no \(language).lproj")
        let url = URL(fileURLWithPath: lproj).appending(path: "\(table).strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String], "no \(language) \(table).strings")
    }

    @Test(arguments: ["Refusals", "MiscHandlers", "Handlers"])
    func everyKeyShipsInEnglishAndJapanese(_ table: String) throws {
        let en = try Self.compiled(table, "en")
        let ja = try Self.compiled(table, "ja")
        #expect(!en.isEmpty)
        #expect(Set(en.keys) == Set(ja.keys), "\(table): \(Set(en.keys).symmetricDifference(ja.keys).sorted())")
        for (key, english) in en {
            let japanese = try #require(ja[key])
            #expect(!japanese.isEmpty, "\(key)")
            #expect(Self.placeholders(english) == Self.placeholders(japanese), "\(key) placeholders differ")
        }
    }

    @Test func japaneseDiffersFromEnglishForSentences() throws {
        let ja = try Self.compiled("Refusals", "ja")
        let en = try Self.compiled("Refusals", "en")
        let untranslated = en.filter { key, value in value.contains(" ") && ja[key] == value }.keys.sorted()
        #expect(untranslated.isEmpty, "\(untranslated)")
    }

    @Test func formattedRefusalsSubstituteArguments() {
        #expect(RefusalStrings.noTab("t42") == "no tab t42")
        #expect(RefusalStrings.screenCount(3) == "the workspace has 3 screens")
        #expect(RefusalStrings.needsDaemonCapability("tab-groups-v1") == "needs daemon capability tab-groups-v1")
        #expect(RefusalStrings.moveColumnUnsupported("move-column", 2)
            == "needs daemon capability move-column (the column has 2 panes; swap-pane moves one)")
        #expect(RefusalStrings.noPaneInDirection(RefusalStrings.direction(.left)) == "no pane left of the focused pane")
        #expect(ActionFailure.needsAppCapability("updates").message == "needs app capability updates")
    }

    /// Format specifiers, ignoring positional prefixes (`%1$@` == `%@`).
    private static func placeholders(_ text: String) -> [String] {
        let regex = /%(?:\d+\$)?(@|lld|d)/
        return text.matches(of: regex).map { String($0.output.1) }.sorted()
    }
}

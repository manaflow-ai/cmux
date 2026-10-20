import Foundation
import Testing

/// Every agent.render_preview error has a translation in every locale of the target's catalog.
struct AgentRenderPreviewLocalizationTests {
    @Test func previewErrorsAreTranslatedInEveryLocale() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = package.appendingPathComponent("Sources/CmuxNextAgentPane")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("Resources/Localizable.xcstrings"))) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: [String: Any]])
        let locales = Set(strings.values.flatMap { ($0["localizations"] as? [String: Any])?.keys.map { $0 } ?? [] })
        #expect(locales.count == 21)
        for suffix in ["invalidParams", "invalidWidth", "noLocalPane", "globalBusy", "disabled", "busy", "timeout", "notLaidOut", "failed"] {
            let key = "agentPane.renderPreview.\(suffix)"
            let entry = try #require(strings[key])
            let translations = try #require(entry["localizations"] as? [String: [String: Any]])
            #expect(Set(translations.keys) == locales)
            for locale in locales {
                let unit = try #require(translations[locale]?["stringUnit"] as? [String: String])
                #expect(unit["state"] == "translated")
                #expect(unit["value"]?.isEmpty == false)
                if locale != "en" {
                    let english = translations["en"]?["stringUnit"] as? [String: String]
                    #expect(unit["value"] != english?["value"])
                }
            }
        }
    }
}

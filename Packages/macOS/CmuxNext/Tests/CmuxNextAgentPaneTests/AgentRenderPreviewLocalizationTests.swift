import Foundation
import Testing

/// Guards the localized key path as well as all locales of the target's native catalog.
struct AgentRenderPreviewLocalizationTests {
    @Test func previewErrorsUseTheAgentPaneCatalog() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = package.appendingPathComponent("Sources/CmuxNextAgentPane")
        let requests = try String(contentsOf: source.appendingPathComponent("AgentRenderPreviewRequests.swift"), encoding: .utf8)
        let errors = try String(contentsOf: source.appendingPathComponent("AgentPaneRenderPreviewError.swift"), encoding: .utf8)
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("Resources/Localizable.xcstrings"))) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: [String: Any]])
        let locales = Set(strings.values.flatMap { ($0["localizations"] as? [String: Any])?.keys.map { $0 } ?? [] })
        #expect(locales.count == 21)
        for (suffix, text) in [("invalidParams", requests), ("invalidWidth", requests), ("noLocalPane", requests), ("globalBusy", requests),
                               ("disabled", errors), ("busy", errors), ("timeout", errors), ("notLaidOut", errors), ("failed", errors)] {
            let key = "agentPane.renderPreview.\(suffix)"
            #expect(text.contains("String(localized: \"\(key)\""), "\(key) must use the native localized lookup")
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

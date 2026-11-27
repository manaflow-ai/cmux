@testable import CmuxNextSettings
import Foundation
import Testing

/// cmux ships the Minimal and Classic New Tab pages (and Terminal). Cards, Default, Threads and
/// Console no longer ship (Leo 2026-11-18: "The templates should be like the customixastikms api you
/// can build them i don't think they should ship as is"): each is a `cmux.newtab/1` template a person
/// builds (skills/cmux-customization/templates/newtab-*). A saved retired id, like the legacy
/// Composer one, still reads, as Minimal. Minimal (Leo 2026-10-20) is the schema's default and the
/// first choice.
struct NewTabTemplateCardsTests {
    @Test(arguments: ["composer", "cards", "default", "threads", "console"])
    func aRetiredTemplateReadsAsMinimal(_ saved: String) throws {
        let root = try JSONValue.parse(Data(#"{"tabs":{"newTabTemplate":"\#(saved)"}}"#.utf8))
        let (template, diagnostic) = NewTabTemplate.parse(root)
        #expect(template == .minimal)
        #expect(diagnostic == nil)
    }

    @Test func classicAndTerminalStillRead() throws {
        for saved in ["classic", "terminal"] {
            let root = try JSONValue.parse(Data(#"{"tabs":{"newTabTemplate":"\#(saved)"}}"#.utf8))
            #expect(NewTabTemplate.parse(root).0?.rawValue == saved)
        }
    }

    @Test func minimalIsTheDefaultAndOnlyShippedTemplatesAreChoices() throws {
        #expect(NewTabTemplate.fallback == .minimal)
        let descriptor = try #require(SettingsSchema.descriptor(for: NewTabTemplate.configPath))
        #expect(descriptor.defaultValue == .string("minimal"))
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("tabs.newTabTemplate is not a choice")
            return
        }
        #expect(choices.map(\.value) == ["minimal", "classic", "terminal"])
        #expect(choices.map(\.value) == NewTabTemplate.allCases.filter { !$0.isRetired }.map(\.rawValue))
        #expect(descriptor.isPaletteExposed)
    }
}

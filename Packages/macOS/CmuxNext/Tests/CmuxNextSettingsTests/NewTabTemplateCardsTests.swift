@testable import CmuxNextSettings
import Foundation
import Testing

/// The Cards New Tab template (u2851: "make our new tab page look like this. Have an option for
/// this version of it"): `tabs.newTabTemplate: "cards"` is a valid value, and the earlier templates
/// stay choices beside it. Minimal (Leo 2026-10-20) is the schema's default (what Settings, the
/// palette and `cmux settings` show for an unset key) and the first choice.
struct NewTabTemplateCardsTests {
    @Test func legacyComposerReadsAsMinimal() throws {
        let root = try JSONValue.parse(Data(#"{"tabs":{"newTabTemplate":"composer"}}"#.utf8))
        let (template, diagnostic) = NewTabTemplate.parse(root)
        #expect(template == .minimal)
        #expect(diagnostic == nil)
    }

    @Test func cardsIsAValidSavedTemplate() throws {
        let root = try JSONValue.parse(Data(#"{"tabs":{"newTabTemplate":"cards"}}"#.utf8))
        let (template, diagnostic) = NewTabTemplate.parse(root)
        #expect(template == .cards)
        #expect(diagnostic == nil)
    }

    @Test func minimalIsTheDefaultAndEveryOtherTemplateStaysAChoice() throws {
        #expect(NewTabTemplate.fallback == .minimal)
        let descriptor = try #require(SettingsSchema.descriptor(for: NewTabTemplate.configPath))
        #expect(descriptor.defaultValue == .string("minimal"))
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("tabs.newTabTemplate is not a choice")
            return
        }
        #expect(choices.map(\.value) == ["minimal", "cards", "default", "threads", "console", "classic", "terminal"])
        #expect(descriptor.isPaletteExposed)
    }
}

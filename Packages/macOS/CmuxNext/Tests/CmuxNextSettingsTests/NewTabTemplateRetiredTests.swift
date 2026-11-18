@testable import CmuxNextSettings
import Foundation
import Testing

/// The New Tab templates that no longer ship (Leo 2026-11-18: "The templates should be like the
/// customixastikms api you can build them i don't think they should ship as is"): Cards, Default,
/// Threads and Console moved to looks, as the legacy Composer was retired before them. A saved one
/// reads as Minimal with no diagnostic, and Settings offers Minimal, Classic and Terminal only.
/// Minimal (Leo 2026-10-20) is the schema's default and the first choice.
struct NewTabTemplateRetiredTests {
    @Test(arguments: ["composer", "cards", "default", "threads", "console"])
    func aRetiredTemplateReadsAsMinimal(_ saved: String) throws {
        let root = try JSONValue.parse(Data(#"{"tabs":{"newTabTemplate":"\#(saved)"}}"#.utf8))
        let (template, diagnostic) = NewTabTemplate.parse(root)
        #expect(template == .minimal)
        #expect(diagnostic == nil)
    }

    @Test func aShippedTemplateReadsAsItself() throws {
        for template in NewTabTemplate.allCases {
            let root = try JSONValue.parse(Data(#"{"tabs":{"newTabTemplate":"\#(template.rawValue)"}}"#.utf8))
            let (read, diagnostic) = NewTabTemplate.parse(root)
            #expect(read == template)
            #expect(diagnostic == nil)
        }
    }

    @Test func anUnknownTemplateIsInvalidAndNamesTheShippedOnes() throws {
        let root = try JSONValue.parse(Data(#"{"tabs":{"newTabTemplate":"sparkles"}}"#.utf8))
        let (template, diagnostic) = NewTabTemplate.parse(root)
        #expect(template == nil)
        #expect(diagnostic?.message == #"expected one of "minimal", "classic", "terminal""#)
    }

    @Test func minimalIsTheDefaultAndTheOnlyChoicesAreTheShippedTemplates() throws {
        #expect(NewTabTemplate.fallback == .minimal)
        #expect(NewTabTemplate.allCases.map(\.rawValue) == ["minimal", "classic", "terminal"])
        let descriptor = try #require(SettingsSchema.descriptor(for: NewTabTemplate.configPath))
        #expect(descriptor.defaultValue == .string("minimal"))
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("tabs.newTabTemplate is not a choice")
            return
        }
        #expect(choices.map(\.value) == ["minimal", "classic", "terminal"])
        #expect(descriptor.isPaletteExposed)
    }
}

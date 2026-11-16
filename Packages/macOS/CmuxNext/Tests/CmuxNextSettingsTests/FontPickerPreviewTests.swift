import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The font picker's preview and write (Leo, 2026-11-08: "this command palette font changing flow
/// is shit"): family and size preview together, the terminal follows the picker's preview (and only
/// the picker's), and Return writes every key in one publish.
@MainActor @Suite(.serialized) struct FontPickerPreviewTests {
    static let family = SettingsSchema.descriptor(for: ["terminal", "fontFamily"])!
    static let size = SettingsSchema.descriptor(for: ["terminal", "fontSize"])!

    @Test func familyAndSizePreviewTogetherAndLeavingRestoresBoth() async throws {
        let home = try ThemeFileTests.Home()
        defer { withExtendedLifetime(home) {} }
        let settings = try ThemeFileTests.controller(home, config: #"{ "terminal": { "fontFamily": "Menlo", "fontSize": 12 } }"#)
        await settings.reload()
        #expect(settings.preview([(Self.family, .string("Monaco")), (Self.size, .number(15))]))
        #expect(settings.applied.terminalFontFamily == "Monaco")
        #expect(settings.applied.terminalFontSize == 15)
        #expect(settings.previewingKeys == ["terminal.fontFamily", "terminal.fontSize"])
        settings.endPreview()
        #expect(settings.applied.terminalFontFamily == "Menlo")
        #expect(settings.applied.terminalFontSize == 12)
        #expect(settings.previewingKeys.isEmpty)
    }

    /// The terminal (which follows `lookFollowed`) shows the font picker's preview, and still not the
    /// Settings window slider's, which would reload Ghostty on every tick.
    @Test func theTerminalFollowsOnlyTheFontPickersPreview() async throws {
        let home = try ThemeFileTests.Home()
        defer { withExtendedLifetime(home) {} }
        let settings = try ThemeFileTests.controller(home, config: #"{ "terminal": { "fontSize": 12 } }"#)
        await settings.reload()
        #expect(settings.preview([(Self.size, .number(20))]))
        #expect(settings.lookFollowed.terminalFontSize == 12)
        settings.previewsTerminalFont = true
        #expect(settings.preview([(Self.family, .string("Monaco")), (Self.size, .number(20))]))
        #expect(settings.lookFollowed.terminalFontSize == 20)
        #expect(settings.lookFollowed.terminalFontFamily == "Monaco")
        settings.endPreview()
        #expect(!settings.previewsTerminalFont)
        #expect(settings.lookFollowed.terminalFontSize == 12)
    }

    @Test func aRefusedValueRefusesTheWholeSet() async throws {
        let home = try ThemeFileTests.Home()
        defer { withExtendedLifetime(home) {} }
        let settings = try ThemeFileTests.controller(home, config: "{}")
        await settings.reload()
        #expect(!settings.preview([(Self.family, .string("Monaco")), (Self.size, .number(400))]))
        #expect(settings.previewingKey == nil)
    }

    @Test func commitWritesEveryKeyInOnePublish() async throws {
        let home = try ThemeFileTests.Home()
        defer { withExtendedLifetime(home) {} }
        let settings = try ThemeFileTests.controller(home, config: #"{ "terminal": { "fontSize": 12 } }"#)
        await settings.reload()
        #expect(settings.preview([(Self.family, .string("Monaco")), (Self.size, .number(16))]))
        try await settings.commitPreview([(Self.family, .string("Monaco")), (Self.size, .number(16))])
        #expect(settings.previewSnapshot == nil)
        #expect(settings.snapshot.terminalFontFamily == "Monaco")
        #expect(settings.snapshot.terminalFontSize == 16)
        let written = try String(contentsOf: home.config, encoding: .utf8)
        #expect(written.contains("Monaco"))
    }
}

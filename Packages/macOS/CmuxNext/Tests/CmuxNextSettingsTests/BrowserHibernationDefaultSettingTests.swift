@testable import CmuxNextSettings
import Testing

/// `browser.hibernation` defaults to "moderate" (Leo, 2026-11-14, "4 yes": hidden browser tabs are
/// discarded by default, after 30 minutes hidden). Before, unset was its own "Never Discard" entry:
/// hidden pages only froze. Settings, the palette, `cmux settings` and MCP read the schema's default.
struct BrowserHibernationDefaultSettingTests {
    private static func row() throws -> SettingDescriptor {
        try #require(SettingsSchema.descriptor(for: BrowserHibernationSetting.configPath))
    }

    private static func root(_ value: JSONValue) -> JSONValue {
        .object(["browser": .object(["hibernation": value])])
    }

    @Test func theDefaultIsModerate() throws {
        let row = try Self.row()
        #expect(row.defaultValue == .string("moderate"))
        #expect(row.defaultLabel == nil)
        #expect(row.effectiveValue(in: .object([:])) == .string("moderate"))
        #expect(!row.isCustomized(in: .object([:])))
        let setting = BrowserHibernationSetting.parse(.object([:])).0
        #expect(setting.mode == .moderate)
        #expect(setting.isEnabled)
        #expect(!setting.isWritten)
    }

    @Test func thePaletteMarksAfter30MinutesByDefault() throws {
        let row = try Self.row()
        let options = row.paletteOptions(current: row.effectiveValue(in: .object([:])), themeColors: [])
        #expect(options.filter(\.isCurrent).map(\.title) == ["After 30 Minutes"])
        #expect(!options.contains { $0.title == "Never Discard" })
    }

    /// "Never" still turns it off.
    @Test func neverIsWrittenAndTurnsItOff() throws {
        let root = Self.root(.string("off"))
        #expect(try Self.row().isCustomized(in: root))
        let setting = BrowserHibernationSetting.parse(root).0
        #expect(!setting.isEnabled)
        #expect(setting.isWritten)
        #expect(try Self.row().paletteOptions(current: .string("off"), themeColors: []).filter(\.isCurrent).map(\.title) == ["Never"])
    }

    @Test(arguments: [JSONValue.string("aggressive"), .string("off"), .number(45)])
    func everyOtherWrittenValueIsCustomized(_ value: JSONValue) throws {
        #expect(try Self.row().isCustomized(in: Self.root(value)))
    }
}

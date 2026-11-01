@testable import CmuxNextSettings
import Testing

/// `browser.hibernation` with nothing written is its own behaviour since "the browser never
/// reloads by itself": hidden pages only freeze and are never discarded on their own. Settings and
/// the palette said "After 30 Minutes" for it, the schema default, which is what an explicit
/// "moderate" does. Unset now shows as "Never Discard"; any written value,
/// "moderate" included, is customized, so Reset appears and goes back to unset.
struct BrowserHibernationUnsetSettingTests {
    private static let unsetLabel = "Never Discard"

    private static func row() throws -> SettingDescriptor {
        try #require(SettingsSchema.descriptor(for: BrowserHibernationSetting.configPath))
    }

    private static func root(_ value: JSONValue) -> JSONValue {
        .object(["browser": .object(["hibernation": value])])
    }

    @Test func unsetHasNoSchemaDefaultAndShowsNeverDiscard() throws {
        let row = try Self.row()
        #expect(row.defaultValue == nil)
        #expect(row.defaultLabel == Self.unsetLabel)
        #expect(row.effectiveValue(in: .object([:])) == nil)
        #expect(!row.isCustomized(in: .object([:])))
        // What unset does: no automatic discards.
        #expect(BrowserHibernationSetting.parse(.object([:])).0.discardsAutomatically == false)
    }

    @Test func anExplicitModerateIsItsOwnValueAndCustomized() throws {
        let row = try Self.row()
        let root = Self.root(.string("moderate"))
        #expect(row.effectiveValue(in: root) == .string("moderate"))
        #expect(row.isCustomized(in: root), "Reset shows: it returns to never discarding")
        #expect(BrowserHibernationSetting.parse(root).0.discardsAutomatically)
    }

    @Test(arguments: [JSONValue.string("moderate"), .string("aggressive"), .string("off"), .number(45)])
    func everyWrittenValueIsCustomized(_ value: JSONValue) throws {
        #expect(try Self.row().isCustomized(in: Self.root(value)))
    }

    @Test func thePaletteListsUnsetFirstAndMarksIt() throws {
        let options = try Self.row().paletteOptions(current: nil, themeColors: [])
        let first = try #require(options.first)
        #expect(first.title == Self.unsetLabel)
        #expect(first.value == nil, "picking it removes the key")
        #expect(first.id == "reset")
        #expect(options.filter(\.isCurrent).map(\.title) == [Self.unsetLabel])
        #expect(options.map(\.value) == [nil, .string("moderate"), .string("aggressive"), .string("off")])
    }

    @Test func thePaletteMarksAWrittenModerateAsAfter30Minutes() throws {
        let options = try Self.row().paletteOptions(current: .string("moderate"), themeColors: [])
        #expect(options.filter(\.isCurrent).map(\.title) == ["After 30 Minutes"])
    }

    @Test func aWrittenTimeoutMarksNeitherUnsetNorAChoice() throws {
        let options = try Self.row().paletteOptions(current: .number(45), themeColors: [])
        #expect(options.allSatisfy { !$0.isCurrent })
    }

    @Test func otherChoiceOrNumberRowsKeepTheirLists() throws {
        // A row with a schema default lists no unset entry (freezeHiddenTabs: 30 s).
        let freeze = try #require(SettingsSchema.descriptor(for: ["browser", "freezeHiddenTabs"]))
        #expect(freeze.paletteOptions(current: nil, themeColors: []).allSatisfy { $0.value != nil })
    }
}

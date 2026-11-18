@testable import CmuxNextSettings
import Testing

/// A list-of-choices setting (`choiceSet`, `orderedChoices`) opened an empty value page in the
/// Command Palette: `paletteOptions` listed nothing for those kinds (`browser.toolbarButtons`,
/// `sidebar.workspaceRow.secondLineOrder` and its per-kind overrides, `tabs.toolbarButtons`). Each
/// choice is now a row, checked while the list holds it; its value is the list with that choice
/// toggled. This walks every such row of the schema, so a new one is covered with no edit here.
struct ChoiceListPaletteOptionTests {
    private static func choices(_ row: SettingDescriptor) -> [SettingChoice]? {
        switch row.kind {
        case .choiceSet(let choices), .orderedChoices(let choices): choices
        default: nil
        }
    }

    private static var choiceListRows: [SettingDescriptor] {
        SettingsSchema.all.filter { $0.isPaletteExposed && choices($0) != nil }
    }

    private static func strings(_ value: JSONValue?) -> [String]? {
        guard case .array(let items)? = value else { return nil }
        return items.compactMap(\.stringValue)
    }

    @Test func theSchemaHasChoiceListRows() {
        let ids = Set(Self.choiceListRows.map(\.id))
        #expect(ids.contains("browser.toolbarButtons"))
        #expect(ids.contains("sidebar.workspaceRow.secondLineOrder"))
    }

    @Test(arguments: [JSONValue?.none, .array([])])
    func everyChoiceListRowListsEachChoice(_ current: JSONValue?) throws {
        for row in Self.choiceListRows {
            let choices = try #require(Self.choices(row))
            let options = row.paletteOptions(current: current, themeColors: [])
            #expect(!options.isEmpty, "\(row.id): the palette's value page is empty")
            let titled = options.filter { $0.value != nil }.map(\.title)
            #expect(Set(titled) == Set(choices.map(\.title)), "\(row.id): one row per choice")
            for option in options {
                if let value = option.value {
                    #expect(row.accepts(value), "\(row.id): \(option.title) writes a value the schema refuses")
                }
            }
            #expect(Set(options.map(\.id)).count == options.count, "\(row.id): option ids repeat")
        }
    }

    @Test func aChoiceSetRowTogglesItsChoiceInChoiceOrder() throws {
        let row = try #require(SettingsSchema.descriptor(for: BrowserToolbarButtonsSetting.configPath))
        let options = row.paletteOptions(current: .array(["media", "zoom", "downloads"].map(JSONValue.string)), themeColors: [])
        let zoom = try #require(options.first { $0.title == "Zoom Level" })
        #expect(zoom.isCurrent)
        #expect(Self.strings(zoom.value) == ["media", "downloads"])
        let bookmarks = try #require(options.first { $0.title == "Bookmarks" })
        #expect(!bookmarks.isCurrent)
        #expect(Self.strings(bookmarks.value) == ["media", "zoom", "favorites", "downloads"])
    }

    @Test func anOrderedChoicesRowListsTheStoredOrderAndTogglesInPlace() throws {
        let row = try #require(SettingsSchema.descriptor(for: WorkspaceRowSetting.orderPath()))
        let options = row.paletteOptions(current: .array(["branch", "directory"].map(JSONValue.string)), themeColors: [])
        #expect(options.prefix(2).map(\.title) == ["Git Branch", "Folder"])
        let folder = try #require(options.first { $0.title == "Folder" })
        #expect(folder.isCurrent)
        #expect(Self.strings(folder.value) == ["branch"])
        let ports = try #require(options.first { $0.title == "Ports" })
        #expect(!ports.isCurrent)
        #expect(Self.strings(ports.value) == ["branch", "directory", "ports"])
    }

    @Test func theRowSummaryNamesWhatTheListHolds() throws {
        let row = try #require(SettingsSchema.descriptor(for: BrowserToolbarButtonsSetting.configPath))
        let held = row.paletteOptions(current: .array(["zoom", "media"].map(JSONValue.string)), themeColors: [])
        #expect(row.paletteSummary(held) == "Media Controls, Zoom Level")
        #expect(row.paletteSummary(row.paletteOptions(current: .array([]), themeColors: [])) == "None")
        let unset = try #require(SettingsSchema.descriptor(for: WorkspaceRowSetting.orderPath(kind: .agent)))
        #expect(unset.paletteSummary(unset.paletteOptions(current: nil, themeColors: [])) == nil)
    }

    @Test func aRowWithNoDefaultOffersUnsetFirst() throws {
        let row = try #require(SettingsSchema.descriptor(for: WorkspaceRowSetting.orderPath(kind: .terminal)))
        #expect(row.defaultValue == nil)
        let unset = try #require(row.paletteOptions(current: nil, themeColors: []).first)
        #expect(unset.value == nil)
        #expect(unset.isCurrent)
    }
}

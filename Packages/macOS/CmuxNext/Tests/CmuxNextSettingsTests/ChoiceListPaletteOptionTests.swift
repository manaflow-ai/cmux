@testable import CmuxNextSettings
import Testing

/// A list-of-choices setting (`choiceSet`, `orderedChoices`) opened an empty value page in the
/// Command Palette: `paletteOptions` listed nothing for those kinds (`browser.toolbarButtons`,
/// `tabs.toolbarButtons`, `sidebar.workspaceRow.secondLineOrder` and its per-kind overrides). This
/// walks every such row of the schema, so a new one is covered with no edit here. A list of what
/// shows (the toolbar buttons) toggles each choice; a full order (the second line) moves a choice
/// to the front and always writes every choice.
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

    private static let secondLine = ["notification", "directory", "branch", "process", "agentStatus", "ports", "lastActivity"]

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
            let titled = options.filter { $0.value != nil }
            #expect(titled.count == choices.count, "\(row.id): one row per choice")
            for choice in choices {
                #expect(titled.contains { $0.title.contains(choice.title) }, "\(row.id): no row for \(choice.title)")
            }
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

    @Test func thePinnedTabBarButtonsToggleAndKeepTheirOrder() throws {
        let row = try #require(SettingsSchema.descriptor(for: PaneToolbarButtonsSetting.configPath))
        let options = row.paletteOptions(current: .array(["splitDown", "splitRight"].map(JSONValue.string)), themeColors: [])
        #expect(options.prefix(2).map(\.title) == ["Split Down", "Split Right"])
        let right = try #require(options.first { $0.title == "Split Right" })
        #expect(right.isCurrent)
        #expect(Self.strings(right.value) == ["splitDown"])
        let diff = try #require(options.first { $0.title == "Diff Viewer" })
        #expect(!diff.isCurrent)
        #expect(Self.strings(diff.value) == ["splitDown", "splitRight", "openDiffViewer"])
    }

    @Test func aSecondLineOrderListsTheWholeOrderAndAMoveKeepsEveryChoice() throws {
        let row = try #require(SettingsSchema.descriptor(for: WorkspaceRowSetting.orderPath()))
        // A stored order that leaves choices out: they follow in the default order, as the app reads it.
        let options = row.paletteOptions(current: .array(["branch", "directory"].map(JSONValue.string)), themeColors: [])
        let applied = ["branch", "directory", "notification", "process", "agentStatus", "ports", "lastActivity"]
        #expect(options.count == applied.count)
        #expect(options.allSatisfy { !$0.isCurrent }, "an order has no checkmarks: unchecking does not hide an item")
        let names = ["Git Branch", "Folder", "Latest Notification", "Running Program", "Agent Status", "Ports", "Last Activity"]
        for (option, name) in zip(options, names) {
            #expect(option.title.contains(name))
        }
        let ports = try #require(options.first { $0.title.contains("Ports") })
        #expect(Self.strings(ports.value) == ["ports", "branch", "directory", "notification", "process", "agentStatus", "lastActivity"])
        for option in options {
            #expect(Set(Self.strings(option.value) ?? []) == Set(Self.secondLine), "\(option.title) drops a choice")
            #expect(Self.strings(option.value)?.count == Self.secondLine.count)
        }
    }

    @Test func aKindOrderWithNoValueOffersSameAsAllFirstAndNeverWritesAPartialList() throws {
        let row = try #require(SettingsSchema.descriptor(for: WorkspaceRowSetting.orderPath(kind: .terminal)))
        #expect(row.defaultValue == nil)
        let options = row.paletteOptions(current: nil, themeColors: [])
        let unset = try #require(options.first)
        #expect(unset.value == nil)
        #expect(unset.isCurrent)
        for option in options.dropFirst() {
            #expect(Set(Self.strings(option.value) ?? []) == Set(Self.secondLine), "\(option.title) writes a partial list")
        }
    }

    @Test func aMoveOnAKindOrderWithNoValueStartsFromTheAllWorkspacesOrder() throws {
        let row = try #require(SettingsSchema.descriptor(for: WorkspaceRowSetting.orderPath(kind: .agent)))
        let root = JSONValue.object(["sidebar": .object(["workspaceRow": .object([
            "secondLineOrder": .array(["ports", "branch"].map(JSONValue.string)),
        ])])])
        let inherited = row.inheritedValue(in: root)
        #expect(Self.strings(inherited) == ["ports", "branch"])
        let options = row.paletteOptions(current: nil, inherited: inherited, themeColors: [])
        #expect(options.first?.value == nil && options.first?.isCurrent == true, "Same as All Workspaces stays first")
        let folder = try #require(options.first { $0.title.contains("Folder") })
        #expect(Self.strings(folder.value) == ["directory", "ports", "branch", "notification", "process", "agentStatus", "lastActivity"])
        #expect(row.paletteSummary(current: nil, options: options) == nil, "unset shows the unset row's title")
        let all = try #require(SettingsSchema.descriptor(for: WorkspaceRowSetting.orderPath()))
        #expect(all.inheritedValue(in: root) == nil, "All Workspaces inherits nothing")
    }

    @Test func theRowSummarySaysWhatApplies() throws {
        let toolbar = try #require(SettingsSchema.descriptor(for: BrowserToolbarButtonsSetting.configPath))
        let held = JSONValue.array(["zoom", "media"].map(JSONValue.string))
        #expect(toolbar.paletteSummary(current: held, options: toolbar.paletteOptions(current: held, themeColors: [])) == "Media Controls, Zoom Level")
        #expect(toolbar.paletteSummary(current: .array([]), options: toolbar.paletteOptions(current: .array([]), themeColors: [])) == "None")
        let order = try #require(SettingsSchema.descriptor(for: WorkspaceRowSetting.orderPath()))
        let stored = JSONValue.array(["branch"].map(JSONValue.string))
        #expect(order.paletteSummary(current: stored, options: order.paletteOptions(current: stored, themeColors: []))
            == "Git Branch, Latest Notification, Folder, Running Program, Agent Status, Ports, Last Activity")
    }
}

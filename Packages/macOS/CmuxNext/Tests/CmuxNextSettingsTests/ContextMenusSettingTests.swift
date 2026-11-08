import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Settings > Menus saves each right-click menu's arrangement in cmux.json `contextMenus`; the
/// registry draws what the file says, Reset removes the menu's key, and a bad entry is reported
/// without breaking the other menus.
@MainActor @Suite(.serialized) struct ContextMenusSettingTests {
    static func settings(_ json: String = "{}") throws -> (SettingsController, ActionRegistry, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-context-menus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(json.utf8).write(to: url)
        let registry = ActionRegistry.standard()
        let settings = SettingsController(registry: registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        return (settings, registry, home)
    }

    private static func file(_ home: URL) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: Data(contentsOf: home.appending(path: "cmux-next.json"))) as? [String: Any]
    }

    @Test func aSavedLayoutReachesTheRegistryAndResetRemovesIt() async throws {
        let (settings, registry, home) = try Self.settings()
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        #expect(registry.contextMenuLayouts.isEmpty)

        let layout = ContextMenuLayout(items: [
            .item("renameWorkspace"), .separator,
            .folder(key: "group:mine", title: "Mine", items: [.item("workspace.duplicate"), .folder(key: ContextMenuLayout.moreKey, title: nil, items: [])]),
        ], hidden: ["home.messageAbout"])
        try await settings.setContextMenuLayout(layout, for: .workspaceRow)
        #expect(registry.contextMenuLayouts[.workspaceRow] == layout)
        let saved = try Self.file(home)?["contextMenus"] as? [String: Any]
        let workspace = (saved?["layouts"] as? [String: Any])?["workspaceRow"] as? [String: Any]
        let items = workspace?["items"] as? [Any]
        #expect(items?.prefix(2).compactMap { $0 as? String } == ["renameWorkspace", "-"])
        let mine = items?.last as? [String: Any]
        #expect(mine?["key"] as? String == "group:mine")
        #expect(mine?["title"] as? String == "Mine")
        #expect((mine?["items"] as? [Any])?.first as? String == "workspace.duplicate")
        #expect(workspace?["hidden"] as? [String] == ["home.messageAbout"])

        try await settings.setShowsCustomizeMenuItem(false)
        #expect(!registry.showsCustomizeMenuItem)

        // Reset: the menu's key goes, then the emptied layouts object; the menu is generated again.
        try await settings.setContextMenuLayout(nil, for: .workspaceRow)
        try await settings.setShowsCustomizeMenuItem(true)
        #expect(registry.contextMenuLayouts[.workspaceRow] == nil)
        #expect(registry.showsCustomizeMenuItem)
        #expect(try Self.file(home)?["contextMenus"] == nil)
    }

    /// The Customize Menu… switch is a schema row (palette, `cmux settings`, MCP), agents may set it
    /// (looks only), and the Settings page leaves it to the Menus card's own switch.
    @Test func theCustomizeMenuSwitchIsASettingOnEverySurface() async throws {
        let row = try #require(SettingsSchema.descriptor(for: ContextMenusSetting.showCustomizeItemPath))
        #expect(row.kind == .toggle)
        #expect(row.isPaletteExposed)
        #expect(!row.isShownOnSettingsPage)
        #expect(SettingsSchema.agentSettableKeys.contains(row.id))
        let (settings, registry, home) = try Self.settings()
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        try await settings.setSetting(at: ContextMenusSetting.showCustomizeItemPath, to: .bool(false), by: .caller("mcp"))
        #expect(!registry.showsCustomizeMenuItem)
    }

    @Test func aBadEntryIsReportedAndTheOthersApply() {
        var diagnostics: [SettingsDiagnostic] = []
        let root: JSONValue = ["contextMenus": [
            "showCustomizeItem": "yes",
            "layouts": [
                "tab": ["items": ["closeTab", ["key": "group:g", "title": "G", "items": ["-"]]], "hidden": ["duplicateTab"]],
                // The first shape still reads: top keys, and More's leading rows.
                "newTab": ["top": ["newSurface", "folder:more"], "more": ["newTab.page"]],
                "notAMenu": ["items": []],
                "pane": ["items": "splitRight"],
                // A submenu of the person's needs a title.
                "screen": ["items": [["key": "group:untitled", "items": []]]],
            ],
        ]]
        let setting = ContextMenusSetting.parse(root, diagnostics: &diagnostics)
        #expect(setting.layouts[.tab] == ContextMenuLayout(items: [.item("closeTab"), .folder(key: "group:g", title: "G", items: [.separator])],
                                                          hidden: ["duplicateTab"]))
        #expect(setting.layouts[.newTab] == ContextMenuLayout(items: [
            .item("newSurface"), .folder(key: ContextMenuLayout.moreKey, title: nil, items: [.item("newTab.page"), .separator]),
        ]))
        #expect(setting.showsCustomizeItem)
        #expect(Set(diagnostics.map(\.path)) == ["contextMenus.showCustomizeItem", "contextMenus.layouts.notAMenu",
                                                 "contextMenus.layouts.pane", "contextMenus.layouts.screen"])
    }
}

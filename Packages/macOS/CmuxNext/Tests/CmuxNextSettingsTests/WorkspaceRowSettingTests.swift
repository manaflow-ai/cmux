import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `sidebar.workspaceRow.*` (SIDEBAR-ROWS-MINIMAL-AND-CUSTOMIZABLE): one toggle
/// per row element, the second line's order, per-kind overrides, and the S1
/// keys read for one release.
@Suite struct WorkspaceRowSettingTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    func row(_ text: String) throws -> WorkspaceRowPreferences { try parse(text).sidebarSections.workspaceRow }

    @Test func theDefaultIsMinimal() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.sidebarSections.workspaceRow == .defaults)
        #expect(WorkspaceRowPreferences.defaults.base.shown == [.icon, .working])
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test(arguments: WorkspaceRowElement.allCases)
    func everyElementHasItsOwnKey(element: WorkspaceRowElement) throws {
        let on = WorkspaceRowElements.minimal.shows(element) ? "false" : "true"
        let parsed = try row(#"{"sidebar": {"workspaceRow": {"\#(element.rawValue)": \#(on)}}}"#)
        #expect(parsed.base.shows(element) != WorkspaceRowElements.minimal.shows(element))
        #expect(parsed.base.shown.symmetricDifference(WorkspaceRowElements.minimal.shown) == [element])
    }

    @Test func theS1KeysStillApplyUntilTheNewKeyIsSet() throws {
        #expect(try row(#"{"sidebar": {"showWorkspaceDirectory": true}}"#).base.shows(.directory))
        #expect(try row(#"{"sidebar": {"showCounts": true}}"#).base.shows(.tabCount))
        #expect(try !row(#"{"sidebar": {"showCounts": true, "workspaceRow": {"tabCount": false}}}"#).base.shows(.tabCount))
    }

    /// Settings > Appearance > Workspace Rows shows what the sidebar draws:
    /// an S1 key that turns an element on shows its new toggle as on.
    @Test func theSettingsPageShowsTheS1ValueUntilTheNewKeyIsSet() throws {
        let directory = try #require(SettingsSchema.descriptor(for: ["sidebar", "workspaceRow", "directory"]))
        let tabCount = try #require(SettingsSchema.descriptor(for: ["sidebar", "workspaceRow", "tabCount"]))
        let legacy = try JSONC.parse(#"{"sidebar": {"showWorkspaceDirectory": true, "showCounts": true}}"#)
        #expect(directory.effectiveValue(in: legacy) == .bool(true))
        #expect(tabCount.effectiveValue(in: legacy) == .bool(true))
        let both = try JSONC.parse(#"{"sidebar": {"showCounts": true, "workspaceRow": {"tabCount": false}}}"#)
        #expect(tabCount.effectiveValue(in: both) == .bool(false))
        let bad = try JSONC.parse(#"{"sidebar": {"showCounts": "yes"}}"#)
        #expect(tabCount.effectiveValue(in: bad) == .bool(false))
    }

    @MainActor @Test func theS1KeysMoveToTheNewKeysOnce() async throws {
        let (settings, url, cleanup) = try Self.controller(#"""
        {
          // mine
          "sidebar": {"showWorkspaceDirectory": true, "showCounts": false, "workspaceRow": {"branch": true}}
        }
        """#)
        defer { cleanup() }
        #expect(try await settings.migrateLegacyWorkspaceRowKeys())
        let text = try String(contentsOf: url, encoding: .utf8)
        let root = try JSONC.parse(text)
        #expect(root.value(at: ["sidebar", "workspaceRow", "directory"]) == .bool(true))
        #expect(root.value(at: ["sidebar", "workspaceRow", "tabCount"]) == .bool(false))
        #expect(root.value(at: ["sidebar", "workspaceRow", "branch"]) == .bool(true))
        #expect(root.value(at: ["sidebar", "showWorkspaceDirectory"]) == nil)
        #expect(root.value(at: ["sidebar", "showCounts"]) == nil)
        #expect(text.contains("// mine"))
        #expect(try await !settings.migrateLegacyWorkspaceRowKeys())
    }

    @MainActor @Test func aSetNewKeyWinsAndABadS1ValueStays() async throws {
        let (settings, url, cleanup) = try Self.controller(#"""
        {"sidebar": {"showCounts": true, "showWorkspaceDirectory": "yes", "workspaceRow": {"tabCount": false}}}
        """#)
        defer { cleanup() }
        #expect(try await settings.migrateLegacyWorkspaceRowKeys())
        let root = try JSONC.parse(try String(contentsOf: url, encoding: .utf8))
        #expect(root.value(at: ["sidebar", "workspaceRow", "tabCount"]) == .bool(false))
        #expect(root.value(at: ["sidebar", "showCounts"]) == nil)
        // A bad value is not moved: it keeps its diagnostic at the S1 key.
        #expect(root.value(at: ["sidebar", "showWorkspaceDirectory"]) == .string("yes"))
        #expect(root.value(at: ["sidebar", "workspaceRow", "directory"]) == nil)
    }

    /// A write of the new toggle (also a reset to the default) removes the S1
    /// key, so the old key can never apply again behind the page.
    @MainActor @Test func writingTheNewToggleRemovesTheS1Key() async throws {
        let (settings, url, cleanup) = try Self.controller(#"{"sidebar": {"showWorkspaceDirectory": true, "showCounts": true}}"#)
        defer { cleanup() }
        let directory = try #require(SettingsSchema.descriptor(for: ["sidebar", "workspaceRow", "directory"]))
        let tabCount = try #require(SettingsSchema.descriptor(for: ["sidebar", "workspaceRow", "tabCount"]))
        try await settings.setSetting(directory, to: nil, by: .user)
        try await settings.setSetting(tabCount, to: .bool(true), by: .user)
        let text = try String(contentsOf: url, encoding: .utf8)
        let root = try JSONC.parse(text)
        #expect(root.value(at: ["sidebar", "showWorkspaceDirectory"]) == nil)
        #expect(root.value(at: ["sidebar", "showCounts"]) == nil)
        #expect(root.value(at: ["sidebar", "workspaceRow", "tabCount"]) == .bool(true))
        #expect(try !row(text).base.shows(.directory))
    }

    @MainActor static func controller(_ text: String) throws -> (SettingsController, URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-row-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(text.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url)
        return (settings, url, { try? FileManager.default.removeItem(at: directory) })
    }

    @Test func aPartialOrderListsItsItemsFirst() throws {
        let parsed = try row(#"{"sidebar": {"workspaceRow": {"secondLineOrder": ["ports", "branch"]}}}"#)
        #expect(parsed.base.secondLineOrder == [.ports, .branch, .directory, .process, .agentStatus, .lastActivity])
    }

    @Test func badValuesKeepDefaultsWithDiagnostics() throws {
        let snapshot = try parse(#"""
        {"sidebar": {"workspaceRow": {"branch": "yes", "secondLineOrder": ["icon"], "terminal": {"ports": 1, "secondLineOrder": "branch"}}}}
        """#)
        #expect(snapshot.sidebarSections.workspaceRow == .defaults)
        #expect(Set(snapshot.diagnostics.map(\.path)) == [
            "sidebar.workspaceRow.branch", "sidebar.workspaceRow.secondLineOrder",
            "sidebar.workspaceRow.terminal.ports", "sidebar.workspaceRow.terminal.secondLineOrder",
        ])
    }

    @Test func aKindOverridesOnlyItsKeys() throws {
        let parsed = try row(#"""
        {"sidebar": {"workspaceRow": {"branch": true,
          "terminal": {"directory": true, "branch": false},
          "agent": {"secondLineOrder": ["agentStatus"], "agentStatus": true}}}}
        """#)
        #expect(parsed.resolved(for: .terminal).secondLine == [.directory])
        #expect(parsed.resolved(for: .agent).secondLine == [.agentStatus, .branch])
        #expect(parsed.resolved(for: .browser).secondLine == [.branch])
        #expect(parsed.overrides[.mixed] == nil)
    }

    @Test func everyElementIsAPageAndPaletteToggleWithItsDefault() throws {
        for element in WorkspaceRowElement.allCases {
            let descriptor = try #require(SettingsSchema.all.first { $0.path == ["sidebar", "workspaceRow", element.rawValue] })
            #expect(descriptor.kind == .toggle)
            #expect(descriptor.defaultValue == .bool(WorkspaceRowElements.minimal.shows(element)))
            #expect(descriptor.section == .appearance)
            #expect(descriptor.isShownOnSettingsPage && descriptor.isPaletteExposed)
            #expect(SettingsSchema.agentSettableKeys.contains(descriptor.id))
        }
        let order = try #require(SettingsSchema.all.first { $0.id == "sidebar.workspaceRow.secondLineOrder" })
        #expect(order.isShownOnSettingsPage)
        #expect(order.accepts(.array([.string("branch"), .string("directory")])))
        #expect(!order.accepts(.array([.string("icon")])))
        for kind in WorkspaceRowKind.allCases {
            let override = try #require(SettingsSchema.all.first { $0.id == "sidebar.workspaceRow.\(kind.rawValue).directory" })
            #expect(override.defaultValue == nil && !override.isShownOnSettingsPage)
        }
        #expect(SettingsSchema.all.allSatisfy { $0.id != "sidebar.showCounts" && $0.id != "sidebar.showWorkspaceDirectory" })
    }
}

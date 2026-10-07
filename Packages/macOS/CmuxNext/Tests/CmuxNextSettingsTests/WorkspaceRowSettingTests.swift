import CmuxNextDesign
import CmuxNextSettings
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

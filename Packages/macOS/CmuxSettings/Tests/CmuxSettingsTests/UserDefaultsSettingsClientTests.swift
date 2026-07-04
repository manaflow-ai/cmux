import Foundation
import Testing
@testable import CmuxSettings

/// Behavior tests for the synchronous ``UserDefaultsSettingsClient`` and the
/// legacy-value decode of the keys the TabManager Wave-3 drain converges
/// onto the catalog.
@Suite("UserDefaultsSettingsClient")
struct UserDefaultsSettingsClientTests {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "cmux-settings-client-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func valueFallsBackToDefaultWhenAbsent() throws {
        let defaults = try makeDefaults()
        let client = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()

        #expect(client.value(for: catalog.app.reorderOnNotification) == true)
        #expect(client.value(for: catalog.sidebar.hideAllDetails) == false)
        #expect(client.value(for: catalog.sidebar.showWorkspaceDescription) == true)
        #expect(client.value(for: catalog.sidebar.showNotificationMessage) == true)
        #expect(client.value(for: catalog.sidebar.branchVerticalLayout) == true)
        #expect(client.value(for: catalog.sidebar.stackBranchDirectory) == false)
        #expect(client.value(for: catalog.sidebar.pathLastSegmentOnly) == false)
        #expect(client.value(for: catalog.sidebar.makePullRequestsClickable) == true)
        #expect(client.value(for: catalog.app.keepWorkspaceOpenWhenClosingLastSurface) == true)
        #expect(client.value(for: catalog.app.workspaceInheritWorkingDirectory) == true)
        #expect(client.value(for: catalog.app.newWorkspacePlacement) == .afterCurrent)
        #expect(client.value(for: catalog.workspaceColors.indicatorStyle) == .leftRail)
        #expect(client.value(for: catalog.workspaceColors.stateColorsEnabled) == false)
        #expect(client.value(for: catalog.workspaceColors.stateColorMode) == .replace)
        #expect(client.value(for: catalog.workspaceColors.stateColors) == WorkspaceColorsCatalogSection.defaultStateColors)
        #expect(client.value(for: catalog.workspaceGroups.anchorCloseSuppressed) == false)
        #expect(client.value(for: catalog.workspaceGroups.newWorkspacePlacement) == .afterCurrent)
        #expect(client.value(for: catalog.terminal.titleUpdateCoalescingEnabled) == false)
        #expect(client.value(for: catalog.terminal.titleUpdateCoalescingMilliseconds) == 500)
        #expect(client.value(for: catalog.terminal.titleUpdateDiagnostics) == false)
    }

    @Test func roundTripsEachConvergedKey() throws {
        let defaults = try makeDefaults()
        let client = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()

        client.set(false, for: catalog.app.reorderOnNotification)
        #expect(client.value(for: catalog.app.reorderOnNotification) == false)
        // The stored representation stays the legacy plain Bool.
        #expect(defaults.object(forKey: "workspaceAutoReorderOnNotification") as? Bool == false)

        client.set(true, for: catalog.workspaceGroups.anchorCloseSuppressed)
        #expect(defaults.object(forKey: "workspaceGroup.anchorCloseSuppressed") as? Bool == true)

        client.set(.top, for: catalog.app.newWorkspacePlacement)
        #expect(defaults.string(forKey: "newWorkspacePlacement") == "top")
        #expect(client.value(for: catalog.app.newWorkspacePlacement) == .top)

        client.set(.solidFill, for: catalog.workspaceColors.indicatorStyle)
        #expect(defaults.string(forKey: "sidebarActiveTabIndicatorStyle") == "solidFill")

        client.set(true, for: catalog.workspaceColors.stateColorsEnabled)
        #expect(defaults.object(forKey: "workspaceColors.stateColorsEnabled") as? Bool == true)

        client.set(.blend, for: catalog.workspaceColors.stateColorMode)
        #expect(defaults.string(forKey: "workspaceColors.stateColorMode") == "blend")
        #expect(client.value(for: catalog.workspaceColors.stateColorMode) == .blend)

        client.set(["running": "#112233"], for: catalog.workspaceColors.stateColors)
        #expect(defaults.dictionary(forKey: "workspaceColors.stateColors") as? [String: String] == ["running": "#112233"])
        #expect(client.value(for: catalog.workspaceColors.stateColors) == ["running": "#112233"])

        client.set(.end, for: catalog.workspaceGroups.newWorkspacePlacement)
        #expect(defaults.string(forKey: "workspaceGroup.newWorkspacePlacement") == "end")
        #expect(client.value(for: catalog.workspaceGroups.newWorkspacePlacement) == .end)

        client.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        #expect(defaults.object(forKey: "terminal.titleUpdates.coalescing.enabled") as? Bool == true)
        #expect(client.value(for: catalog.terminal.titleUpdateCoalescingEnabled) == true)

        client.set(250, for: catalog.terminal.titleUpdateCoalescingMilliseconds)
        #expect(defaults.object(forKey: "terminal.titleUpdates.coalescing.delayMilliseconds") as? Int == 250)
        #expect(client.value(for: catalog.terminal.titleUpdateCoalescingMilliseconds) == 250)

        client.set(true, for: catalog.terminal.titleUpdateDiagnostics)
        #expect(defaults.object(forKey: "terminal.titleUpdates.diagnostics") as? Bool == true)
        #expect(client.value(for: catalog.terminal.titleUpdateDiagnostics) == true)
    }

    @Test func resetRestoresDefault() throws {
        let defaults = try makeDefaults()
        let client = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()

        client.set(true, for: catalog.workspaceGroups.anchorCloseSuppressed)
        client.reset(catalog.workspaceGroups.anchorCloseSuppressed)
        #expect(defaults.object(forKey: "workspaceGroup.anchorCloseSuppressed") == nil)
        #expect(client.value(for: catalog.workspaceGroups.anchorCloseSuppressed) == false)
    }

    @Test func valueIfPresentDistinguishesAbsentFromStoredDefault() throws {
        let defaults = try makeDefaults()
        let client = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()

        #expect(client.valueIfPresent(for: catalog.workspaceColors.palette) == nil)
        client.set([:], for: catalog.workspaceColors.palette)
        #expect(client.valueIfPresent(for: catalog.workspaceColors.palette) == [:])
    }

    @Test func clientAndActorStoreReadTheSameStoredValue() async throws {
        let defaults = try makeDefaults()
        let client = UserDefaultsSettingsClient(defaults: defaults)
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let catalog = SettingCatalog()

        client.set(.end, for: catalog.app.newWorkspacePlacement)
        let storeValue = await store.value(for: catalog.app.newWorkspacePlacement)
        #expect(storeValue == .end)

        await store.set(.top, for: catalog.app.newWorkspacePlacement)
        #expect(client.value(for: catalog.app.newWorkspacePlacement) == .top)
    }
}

@Suite("WorkspaceIndicatorStyle legacy decode")
struct WorkspaceIndicatorStyleLegacyDecodeTests {
    @Test(arguments: [
        ("leftRail", WorkspaceIndicatorStyle.leftRail),
        ("solidFill", .solidFill),
        ("rail", .leftRail),
        ("border", .solidFill),
        ("wash", .solidFill),
        ("lift", .solidFill),
        ("typography", .solidFill),
        ("washRail", .solidFill),
        ("blueWashColorRail", .solidFill),
    ])
    func mapsLegacyRawValues(raw: String, expected: WorkspaceIndicatorStyle) {
        #expect(WorkspaceIndicatorStyle.decodeFromUserDefaults(raw) == expected)
        #expect(WorkspaceIndicatorStyle.decodeFromJSON(raw) == expected)
    }

    @Test func unknownAndNonStringValuesDecodeAsNil() {
        #expect(WorkspaceIndicatorStyle.decodeFromUserDefaults("sparkles") == nil)
        #expect(WorkspaceIndicatorStyle.decodeFromUserDefaults(nil) == nil)
        #expect(WorkspaceIndicatorStyle.decodeFromUserDefaults(7) == nil)
    }

    @Test func encodesModernRawValue() {
        #expect(WorkspaceIndicatorStyle.leftRail.encodeForUserDefaults() as? String == "leftRail")
        #expect(WorkspaceIndicatorStyle.solidFill.encodeForJSON() as? String == "solidFill")
    }
}

@Suite("WorkspaceGroupNewPlacement decode")
struct WorkspaceGroupNewPlacementDecodeTests {
    @Test(arguments: [
        ("afterCurrent", WorkspaceGroupNewPlacement.afterCurrent),
        ("aftercurrent", .afterCurrent),
        ("AFTER-CURRENT", .afterCurrent),
        ("after_current", .afterCurrent),
        ("  top  ", .top),
        ("End", .end),
    ])
    func tolerantRawStringParse(raw: String, expected: WorkspaceGroupNewPlacement) {
        #expect(WorkspaceGroupNewPlacement(rawString: raw) == expected)
        #expect(WorkspaceGroupNewPlacement.decodeFromUserDefaults(raw) == expected)
        #expect(WorkspaceGroupNewPlacement.decodeFromJSON(raw) == expected)
    }

    @Test func rejectsUnknownAndEmptyStrings() {
        #expect(WorkspaceGroupNewPlacement(rawString: nil) == nil)
        #expect(WorkspaceGroupNewPlacement(rawString: "") == nil)
        #expect(WorkspaceGroupNewPlacement(rawString: "   ") == nil)
        #expect(WorkspaceGroupNewPlacement(rawString: "middle") == nil)
        #expect(WorkspaceGroupNewPlacement.decodeFromUserDefaults(true) == nil)
    }

    @Test func encodesCanonicalRawValue() {
        #expect(WorkspaceGroupNewPlacement.afterCurrent.encodeForUserDefaults() as? String == "afterCurrent")
        #expect(WorkspaceGroupNewPlacement.end.encodeForJSON() as? String == "end")
    }
}

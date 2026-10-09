import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

@MainActor
@Suite struct BuiltInButtonMappingTests {
    @Test func everyBuiltInMapsToACatalogAction() {
        let registry = ActionRegistry.standard()
        let ids = ["cmux.newTerminal", "cmux.newBrowser", "cmux.splitRight", "cmux.splitDown", "cmux.newWorkspace",
                   "cmux.newAgentChat", "cmux.newCloudWorkspace", "cmux.newCloudMachine", "cmux.mobileconnect"]
        for id in ids {
            let entry = BuiltInButtonActions.entry(for: id)
            #expect(entry?.configID == id)
            #expect(entry.flatMap { registry.descriptor(for: ActionID(rawValue: $0.actionID)) } != nil, "\(id)")
        }
        #expect(SurfaceTabBarConfig.defaultButtons.isEmpty)
    }

    @Test func aliasesResolveToTheCanonicalEntry() {
        #expect(BuiltInButtonActions.entry(for: "splitRight")?.actionID == "splitRight")
        #expect(BuiltInButtonActions.entry(for: "newTerminal")?.actionID == "newSurface")
        #expect(BuiltInButtonActions.entry(for: "cmux.mobileConnect")?.configID == "cmux.mobileconnect")
        #expect(BuiltInButtonActions.entry(for: "agentChat")?.actionID == "palette.newAgentChat")
        #expect(BuiltInButtonActions.entry(for: "splitLeft") == nil)
    }

    /// TAB-STRIP-TRAILING-BUTTONS-REMOVED: the strip draws no buttons, so
    /// their action names are not checked; the key itself is reported as
    /// ignored (by the file parse, ``SurfaceTabBarRemovedTests``).
    @Test func buttonActionNamesAreNotReported() throws {
        let registry = ActionRegistry.standard()
        let applier = SettingsApplier(design: DesignSettings(), registry: registry)
        let root = try JSONC.parse(#"{"ui": {"surfaceTabBar": {"buttons": ["splitRight", "does.not.exist"]}}}"#)
        let diagnostics = applier.apply(CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities,
                                                                validMetrics: SettingsApplier.validMetrics))
        #expect(diagnostics.filter { $0.path == "ui.surfaceTabBar.buttons" && $0.kind == .unknownAction }.isEmpty)
    }
}

/// TAB-STRIP-TRAILING-BUTTONS-REMOVED: a cmux.json that still sets the tab
/// bar buttons gets one diagnostic saying the key is ignored, instead of
/// silence (or a report of action names nothing runs).
@MainActor
@Suite struct SurfaceTabBarRemovedTests {
    static let message = "ignored: the tab bar buttons were removed"

    func diagnostics(_ text: String) throws -> [SettingsDiagnostic] {
        let root = try JSONC.parse(text)
        return CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities,
                                        validMetrics: SettingsApplier.validMetrics).diagnostics
    }

    @Test func aSetButtonListIsReportedAsIgnored() throws {
        let set = try diagnostics(#"{"ui": {"surfaceTabBar": {"buttons": ["splitRight", "does.not.exist"]}}}"#)
        #expect(set.filter { $0.message == Self.message }.map(\.path) == ["ui.surfaceTabBar.buttons"])
        #expect(set.filter { $0.message == Self.message }.map(\.kind) == [.removedSetting])
        let empty = try diagnostics(#"{"ui": {"surfaceTabBar": {"buttons": []}}}"#)
        #expect(empty.filter { $0.message == Self.message }.map(\.path) == ["ui.surfaceTabBar.buttons"])
        let wrongType = try diagnostics(#"{"ui": {"surfaceTabBar": {"buttons": "splitRight"}}}"#)
        #expect(wrongType.map(\.message) == [Self.message])
        let legacy = try diagnostics(#"{"surfaceTabBarButtons": ["splitDown"]}"#)
        #expect(legacy.filter { $0.message == Self.message }.map(\.path) == ["surfaceTabBarButtons"])
    }

    @Test func anUnsetButtonListIsNotReported() throws {
        #expect(try diagnostics("{}").filter { $0.message == Self.message }.isEmpty)
    }
}


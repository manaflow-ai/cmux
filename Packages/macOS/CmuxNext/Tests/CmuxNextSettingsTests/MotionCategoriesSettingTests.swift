import CmuxNextActions
import CmuxNextAppearance
import CmuxNextDesignTokens
@testable import CmuxNextSettings
import Testing

/// `ui.animations.enabled` and `ui.animations.<category>` (plans/cmux-next/motion-DESIGN.md):
/// cmux.json reaches `DesignSettings`, Settings > Appearance > Motion has a row for each, and
/// each has a palette, CLI and MCP toggle that writes the key and flips the live switch.
@MainActor @Suite struct MotionCategoriesSettingTests {
    private func snapshot(_ animations: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["ui": .object(["animations": .object(animations)])]), validDensities: [], validMetrics: [])
    }

    @Test func everythingAnimatesWhenCmuxJSONSaysNothing() {
        let parsed = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(parsed.motionCategories == MotionCategoriesSetting(enabled: true, disabled: []))
    }

    @Test func theMasterSwitchAndEachCategoryParse() {
        var animations: [String: JSONValue] = ["enabled": .bool(false)]
        for category in MotionCategory.allCases { animations[category.configKey] = .bool(false) }
        let parsed = snapshot(animations)
        #expect(parsed.motionCategories.enabled == false)
        #expect(parsed.motionCategories.disabled == Set(MotionCategory.allCases))
        #expect(parsed.diagnostics.isEmpty)
    }

    @Test(arguments: MotionCategory.allCases)
    func oneCategoryOffLeavesTheOthersOn(_ category: MotionCategory) {
        let parsed = snapshot([category.configKey: .bool(false)])
        #expect(parsed.motionCategories.enabled)
        #expect(parsed.motionCategories.disabled == [category])
    }

    @Test func aValueThatIsNotABoolIsTheDefaultPlusADiagnostic() {
        let parsed = snapshot(["enabled": .string("no"), "tabs": .number(0)])
        #expect(parsed.motionCategories == MotionCategoriesSetting())
        let paths = Set(parsed.diagnostics.map(\.path))
        #expect(paths.contains("ui.animations.enabled"))
        #expect(paths.contains("ui.animations.tabs"))
    }

    @Test func theApplierSetsTheLiveSwitches() {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry())
        _ = applier.apply(snapshot(["enabled": .bool(false), "sidebar": .bool(false)]))
        #expect(design.animationsEnabled == false)
        #expect(design.disabledAnimationCategories == [.sidebar])
        _ = applier.apply(snapshot([:]))
        #expect(design.animationsEnabled)
        #expect(design.disabledAnimationCategories.isEmpty)
    }

    @Test func settingsHasAMotionRowForTheMasterSwitchAndEveryCategory() {
        let master = SettingsSchema.descriptor(for: MotionCategoriesSetting.enabledPath)
        #expect(master?.section == .appearance)
        for category in MotionCategory.allCases {
            let row = SettingsSchema.descriptor(for: MotionCategoriesSetting.path(category))
            #expect(row != nil, "no Settings row for ui.animations.\(category.configKey)")
            #expect(row?.section == .appearance)
            #expect(row?.group == master?.group, "\(category) is not in the Motion group")
        }
    }

    @Test func everySwitchHasAPaletteCLIAndMCPAction() {
        let ids = [MotionCategoriesSetting.masterActionID] + MotionCategory.allCases.map(MotionCategoriesSetting.actionID)
        for id in ids {
            let descriptor = ActionCatalog.all.first { $0.id.rawValue == id }
            #expect(descriptor != nil, "\(id) is not in the action catalog")
            #expect(descriptor?.surfaces.contains(.palette) == true, "\(id) is not in Cmd-Shift-P")
            #expect(descriptor?.cliName.isEmpty == false, "\(id) has no CLI verb")
        }
    }

    @Test func theTogglesWriteTheKeyAndFlipTheLiveSwitch() throws {
        let design = DesignSettings()
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        var writes: [(String, JSONValue?)] = []
        func last() throws -> (path: String, value: JSONValue?) { try #require(writes.last) }
        MotionCategoriesSetting.bindActions(into: registry, design: design) { path, value in
            writes.append((path.joined(separator: "."), value))
            return nil
        }
        #expect(registry.perform(ActionID(rawValue: MotionCategoriesSetting.masterActionID)))
        #expect(design.animationsEnabled == false)
        #expect(try last().path == "ui.animations.enabled")
        #expect(try last().value == JSONValue.bool(false))
        #expect(registry.perform(ActionID(rawValue: MotionCategoriesSetting.masterActionID)))
        #expect(design.animationsEnabled)
        #expect(try last().value == nil, "back on did not remove the key")

        #expect(registry.perform(ActionID(rawValue: MotionCategoriesSetting.actionID(.tabs))))
        #expect(design.disabledAnimationCategories == [.tabs])
        #expect(try last().path == "ui.animations.tabs")
        #expect(try last().value == JSONValue.bool(false))
        #expect(registry.perform(ActionID(rawValue: MotionCategoriesSetting.actionID(.tabs))))
        #expect(design.disabledAnimationCategories.isEmpty)
    }

    @Test func aManagedKeyRefusesAndChangesNothing() {
        let design = DesignSettings()
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        MotionCategoriesSetting.bindActions(into: registry, design: design) { _, _ in "managed by your organization" }
        registry.perform(ActionID(rawValue: MotionCategoriesSetting.actionID(.web)))
        #expect(design.disabledAnimationCategories.isEmpty)
    }
}

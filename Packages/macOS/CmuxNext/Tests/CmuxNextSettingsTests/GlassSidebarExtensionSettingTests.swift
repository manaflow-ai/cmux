import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Testing

/// `experiments.glassSidebarExtension` (Settings > Experimental > Experiments, taste build
/// 2026-11-19): one default-off toggle on every surface, parsed like a Labs toggle, and copied
/// into `DesignSettings.glassSidebarExtension` by the settings applier.
@MainActor struct GlassSidebarExtensionSettingTests {
    private func snapshot(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["experiments": .object(["glassSidebarExtension": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func isOneDefaultOffToggleInTheExperimentsGroup() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.glassSidebarExtensionPath))
        #expect(CmuxConfigSnapshot.glassSidebarExtensionDefault == false)
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.isPaletteExposed)
        #expect(SettingsSchema.agentSettableKeys.contains(descriptor.id))
        #expect(CmuxConfigSnapshot.empty.glassSidebarExtension == false)
    }

    @Test func absentIsOffWithNoDiagnostic() {
        let parsed = snapshot(nil)
        #expect(parsed.glassSidebarExtension == false)
        #expect(!parsed.diagnostics.map(\.path).contains("experiments.glassSidebarExtension"))
    }

    @Test func trueParses() {
        #expect(snapshot(.bool(true)).glassSidebarExtension == true)
    }

    @Test func aValueThatIsNotABoolIsOffPlusADiagnostic() {
        let parsed = snapshot(.string("yes"))
        #expect(parsed.glassSidebarExtension == false)
        #expect(parsed.diagnostics.map(\.path).contains("experiments.glassSidebarExtension"))
    }

    @Test func theApplierCopiesItIntoDesignSettings() {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry())
        _ = applier.apply(snapshot(.bool(true)))
        #expect(design.glassSidebarExtension == true)
        _ = applier.apply(snapshot(nil))
        #expect(design.glassSidebarExtension == false)
    }
}

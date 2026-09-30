import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Testing

/// `shortcuts.tiers.<actionID>` moves an action between key routing tiers
/// (plans/cmux-next/focus.md section 5); removing it restores the default.
@MainActor
struct KeyTierSettingsTests {
    @Test func configTiersParseAndApply() {
        let root: JSONValue = ["shortcuts": ["tiers": ["splitRight": "content", "quit": "bogus"]]]
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.keyTiers == ["splitRight": "content"])
        #expect(snapshot.diagnostics.contains { $0.path == "shortcuts.tiers.quit" })
        #expect(snapshot.shortcuts["tiers"] == nil, "tiers is not an action id")
        let registry = ActionRegistry.standard()
        let applier = SettingsApplier(design: DesignSettings(), registry: registry)
        applier.apply(snapshot)
        #expect(registry.keyTier(for: "splitRight") == .content)
        applier.apply(CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: []))
        #expect(registry.keyTier(for: "splitRight") == .navigation)
    }
}

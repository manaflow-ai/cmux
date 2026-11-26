@testable import CmuxNextSettings
import Testing

/// `limitedToCatalog` keeps catalog keys and their older names, and an empty layer comes back as it was
/// (launch merges `.none` before NSApplication exists, so it must not build `SettingsSchema.all`; CMUX-631).
struct TeamPolicyLayerCatalogTests {
    @Test func anEmptyLayerFiltersToItself() {
        #expect(TeamPolicyLayer.none.limitedToCatalog() == .none)
        let named = TeamPolicyLayer(teamName: "Team", teamID: "t1", version: 3)
        #expect(named.limitedToCatalog() == named)
    }

    @Test func aLayerKeepsOnlyCatalogKeys() {
        let key = SettingsSchema.all[0].id
        let layer = TeamPolicyLayer(defaults: [key: .bool(true), "notASetting.key": .bool(true)],
                                    enforced: ["notASetting.other": .bool(false)])
        let limited = layer.limitedToCatalog()
        #expect(limited.defaults == [key: .bool(true)])
        #expect(limited.enforced.isEmpty)
    }
}

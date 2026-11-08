import CmuxNextSettings
import Testing

/// `home.chiefPanel.style` (user 2026-11-07): how the floating Chief looks, switched in Settings > Chief; the compose
/// bar when unset, the most minimal style that still takes a message.
struct ChiefPanelStyleSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["home": .object(["chiefPanel": .object(["style": $0])])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func theComposeBarWhenUnsetAndEachStyleIsKept() throws {
        #expect(Self.parse(nil).chiefPanelStyle == "composeBar")
        for style in ["composeBar", "pill", "card", "panel", "bubble", "seeThrough", "seeThroughBar"] {
            let snapshot = Self.parse(.string(style))
            #expect(snapshot.chiefPanelStyle == style && snapshot.diagnostics.isEmpty, "\(style)")
        }
        let bad = Self.parse(.string("huge"))
        #expect(bad.chiefPanelStyle == "composeBar" && !bad.diagnostics.isEmpty, "an unknown style is not reported")
        let row = try #require(SettingsSchema.descriptor(for: ChiefDockSetting.stylePath), "no Settings row")
        #expect(row.defaultValue == .string("composeBar"))
    }

    /// `home.chiefPanel.seesScreen`: the floating Chief's "sees your screen" eye; on when unset.
    @Test func seesScreenIsOnWhenUnset() throws {
        let unset = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(unset.chiefPanelSeesScreen)
        let off = CmuxConfigSnapshot.parse(.object(["home": .object(["chiefPanel": .object(["seesScreen": .bool(false)])])]),
                                           validDensities: [], validMetrics: [])
        #expect(!off.chiefPanelSeesScreen)
        let row = try #require(SettingsSchema.descriptor(for: ChiefDockSetting.seesScreenPath), "no Settings row")
        #expect(row.defaultValue == .bool(true))
    }
}

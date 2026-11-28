import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `appearance.toolbarButtonStyle` (Leo 2026-11-18: "prob likewise the session info and the top right buttons as
/// well"): today's look unless set; plain, grouped and glass apply; a bad value keeps today's and says so; a theme
/// file may set it.
@MainActor struct ToolbarButtonStyleSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let appearance: [String: JSONValue] = value.map { ["toolbarButtonStyle": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
    }

    @Test func standardByDefaultWithASettingsRow() {
        let snapshot = Self.parse(nil)
        #expect(ToolbarButtonStyleSetting.effective(in: snapshot) == .standard)
        #expect(snapshot.diagnostics.isEmpty)
        #expect(SettingsSchema.descriptor(for: ["appearance", "toolbarButtonStyle"]) != nil, "a Settings row, so the palette lists it")
        #expect(SettingsSchema.agentSettableKeys.contains("appearance.toolbarButtonStyle"))
        let row = SettingsSchema.descriptor(for: ["appearance", "toolbarButtonStyle"])
        #expect(row.map(ThemeFileOverlay.isLook) == true, "a theme file may set it")
    }

    @Test func eachStyleApplies() {
        for style in ToolbarButtonStyle.allCases {
            let snapshot = Self.parse(.string(style.rawValue))
            #expect(snapshot.diagnostics.isEmpty)
            let design = DesignSettings()
            SettingsApplier.applyPlacement(snapshot, to: design)
            #expect(design.toolbarButtonStyle == style)
        }
    }

    @Test func aBadValueKeepsStandardAndSaysSo() {
        for bad: JSONValue in [.string("shiny"), .number(1)] {
            let snapshot = Self.parse(bad)
            #expect(ToolbarButtonStyleSetting.effective(in: snapshot) == .standard)
            #expect(snapshot.diagnostics.contains { $0.path == "appearance.toolbarButtonStyle" })
        }
    }

    @Test func onlyThePillStylesDrawAGroupAndOnlyStandardKeepsTheTabBarsHover() {
        #expect(ToolbarButtonStyle.allCases.filter(\.drawsGroup) == [.grouped, .glass])
        #expect(ToolbarButtonStyle.standard.hoverStyle == nil)
        #expect(ToolbarButtonStyle.plain.hoverStyle == .glyph)
    }
}

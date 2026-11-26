import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `appearance.menu.*` and `appearance.popover.*`: unset is today's look, set keys read into
/// ``MenuLook``, a bad value is today's plus a diagnostic.
struct MenuLookSettingTests {
    private func parse(_ appearance: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
    }

    @Test func missingKeysAreTodaysLook() {
        let snapshot = parse([:])
        #expect(MenuLookSetting.effective(in: snapshot) == MenuLook.standard)
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("appearance.menu") || $0.path.hasPrefix("appearance.popover") })
    }

    @Test func theClaudeFragmentReads() {
        let snapshot = parse([
            "menu": .object([
                "cornerRadius": .number(12), "borderOpacity": .number(0.1), "fill": .string("#2b2b2b"),
                "padding": .number(8), "highlightRadius": .number(8), "rowHeight": .number(30),
                "shortcuts": .string("muted"), "sectionLabel": .string("muted"), "separator": .string("subtle"),
                "submenu": .string("flush"), "subtitle": .string("muted"),
            ]),
            "popover": .object(["padding": .number(12), "header": .string("strong"), "progressHeight": .number(6)]),
        ])
        let look = MenuLookSetting.effective(in: snapshot)
        #expect(look.cornerRadius == 12)
        #expect(look.fill == ThemeRGB(hex: 0x2B2B2B))
        #expect(look.rowHeight == 30)
        #expect(look.shortcuts == .muted)
        #expect(look.submenu == .flush)
        #expect(look.popoverHeader == .strong)
        #expect(look.progressHeight == 6)
        #expect(look.destructiveInk == .standard)
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("appearance.menu") || $0.path.hasPrefix("appearance.popover") })
    }

    @Test func badValuesAreTodaysLookAndReported() {
        let snapshot = parse(["menu": .object(["shadow": .string("huge"), "fill": .string("red"), "rowHeight": .number(99)])])
        let look = MenuLookSetting.effective(in: snapshot)
        #expect(look.shadow == .standard)
        #expect(look.fill == nil)
        #expect(look.rowHeight == 40) // clamped to the schema's range
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.menu.shadow" && $0.message.hasPrefix("expected one of") })
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.menu.fill" })
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.menu.rowHeight" })
    }
}

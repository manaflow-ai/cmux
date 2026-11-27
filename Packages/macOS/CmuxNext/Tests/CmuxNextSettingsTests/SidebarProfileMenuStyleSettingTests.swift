import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `sidebar.profileMenu.style` (ask-aad661801e: "make customization for codex, t3code, claude code app
/// (everything)"): cmux's app menu by default; the Claude Code and Codex looks pick the account menu. A bad value
/// keeps the default and says why.
struct SidebarProfileMenuStyleSettingTests {
    private static let path = ["sidebar", "profileMenu", "style"]

    private func snapshot(_ style: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = style.map { .object(["sidebar": .object(["profileMenu": .object(["style": $0])])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func absentIsTheAppMenu() {
        #expect(snapshot(nil).sidebarSections.profileMenuStyle == .app)
    }

    @Test(arguments: [("app", SidebarProfileMenuStyle.app), ("account", .account)])
    func eachChoiceIsRead(raw: String, style: SidebarProfileMenuStyle) {
        let parsed = snapshot(.string(raw))
        #expect(parsed.sidebarSections.profileMenuStyle == style)
        #expect(!parsed.diagnostics.contains { $0.path == "sidebar.profileMenu.style" })
    }

    @Test func aBadValueKeepsTheDefaultWithADiagnostic() {
        let parsed = snapshot("accounts")
        #expect(parsed.sidebarSections.profileMenuStyle == .app)
        #expect(parsed.diagnostics.contains { $0.path == "sidebar.profileMenu.style" })
    }

    @Test func theSchemaListsItForEverySurface() throws {
        let row = try #require(SettingsSchema.descriptor(for: Self.path))
        #expect(row.defaultValue == .string("app"))
        guard case let .choice(choices) = row.kind else {
            Issue.record("sidebar.profileMenu.style is not a choice")
            return
        }
        #expect(choices.map(\.value) == ["app", "account"])
        #expect(SettingsSchema.agentSettableKeys.contains("sidebar.profileMenu.style"))
    }
}

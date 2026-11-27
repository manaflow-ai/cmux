import CmuxNextDesign
import CmuxNextSettings
import Testing

struct SidebarGroupBackgroundSettingTests {
    private func snapshot(_ value: String? = nil) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map {
            .object(["sidebar": .object(["groupHeader": .object(["background": .string($0)])])])
        } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func missingSettingAndSettingsResetUseAutomatic() throws {
        #expect(snapshot().sidebarSections.groupHeaderBackground == .auto)
        let row = try #require(SettingsSchema.descriptor(for: SidebarSectionsSetting.groupHeaderBackgroundPath))
        #expect(row.defaultValue == .string("auto"))
    }

    @Test func invalidSettingUsesAutomaticAndReportsTheKey() {
        let parsed = snapshot("unknown")
        #expect(parsed.sidebarSections.groupHeaderBackground == .auto)
        #expect(parsed.diagnostics.contains { $0.path == "sidebar.groupHeader.background" })
    }

    @Test(arguments: SidebarGroupBackgroundStyle.allCases)
    func everyExplicitLookIsPreserved(_ style: SidebarGroupBackgroundStyle) {
        #expect(snapshot(style.rawValue).sidebarSections.groupHeaderBackground == style)
    }
}

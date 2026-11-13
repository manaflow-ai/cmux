import CmuxNextDesignTokens
import CmuxNextSettingsWindow
@testable import CmuxNextSidebar
import Testing

/// The tuning panel's Copy Values text (`TuningPanelExport`): one Swift constant per tunable, typed by its kind,
/// with the default noted only when the value moved, so the tuned numbers paste straight into the tokens.
@MainActor @Suite struct TuningPanelExportTests {
    let export = TuningPanelExport(choiceType: { $0.key.hasSuffix("Weight") ? "NSFont.Weight" : nil })

    @Test func eachTunablePrintsOneTypedConstant() {
        let height = SidebarRowTuning.rowHeight.descriptor
        let opacity = SidebarRowTuning.glyphOpacity.descriptor
        let weight = SidebarRowTuning.titleWeight.descriptor
        let text = export.swiftConstants(title: "Sidebar Row Tuner", rows: [
            (height, .number(26), .number(24)),
            (opacity, .number(1), .number(1)),
            (weight, .choice("medium"), .choice("regular")),
        ])
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("// Sidebar Row Tuner"))
        #expect(lines[1] == "static let rowHeight: CGFloat = 26 // sidebarRows.rowHeight, was 24")
        #expect(lines[2] == "static let glyphOpacity: Double = 1 // sidebarRows.glyphOpacity")
        #expect(lines[3] == "static let titleWeight: NSFont.Weight = .medium // sidebarRows.titleWeight, was .regular")
    }

    @Test func aChoiceWithoutASwiftTypePrintsItsRawValue() {
        let weight = SidebarRowTuning.headingWeight.descriptor
        let text = TuningPanelExport().swiftConstants(title: "T", rows: [(weight, .choice("bold"), .choice("bold"))])
        #expect(text.hasSuffix("static let headingWeight: String = \"bold\" // sidebarRows.headingWeight"))
    }

    @Test func theTunerListsEveryRowTunableOnce() {
        let keys = SidebarRowTuning.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.hasPrefix("sidebarRows.") })
        #expect(SidebarRowTuning.all.allSatisfy { $0.section.id == SidebarRowTuning.section.id })
    }
}

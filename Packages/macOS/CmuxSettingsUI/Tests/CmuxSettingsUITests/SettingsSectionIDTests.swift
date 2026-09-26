import Testing
@testable import CmuxSettingsUI

@Suite("SettingsSectionID")
struct SettingsSectionIDTests {
    @Test func everyCaseHasNonEmptyTitleAndSymbol() {
        for section in SettingsSectionID.allCases {
            #expect(!section.title.isEmpty)
            #expect(!section.symbolName.isEmpty)
        }
    }

    @Test func titlesAreUnique() {
        let titles = SettingsSectionID.allCases.map(\.title)
        #expect(titles.count == Set(titles).count)
    }

    /// Devices keeps the persisted `computers` raw value and sits right after
    /// Mobile, so search ties and the detail stack follow the sidebar (#14771).
    @Test func devicesIsItsOwnSectionAfterMobile() {
        let cases = SettingsSectionID.allCases
        #expect(SettingsSectionID.computers.title == "Devices")
        #expect(SettingsSectionID(rawValue: "computers") == .computers)
        #expect(cases.firstIndex(of: .computers) == cases.firstIndex(of: .mobile).map { $0 + 1 })
    }
}

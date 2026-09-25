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

    @Test func computersIsOnlyACompatibilityAliasForMobile() {
        #expect(SettingsSectionID.computers.canonicalSection == .mobile)
        #expect(!SettingsSectionID.computers.isVisibleSection)
        #expect(!SettingsSectionID.visibleCases.contains(.computers))
        #expect(SettingsSectionID.computersSubsectionAnchorID == "setting:mobile:computers")
        #expect(SettingsSectionID.canonicalAnchorID("section:computers") == "setting:mobile:computers")
        #expect(SettingsSectionID.canonicalAnchorID("setting:computers:pair") == "setting:mobile:computers")
        #expect(
            SettingsSectionID.canonicalNavigationAnchor(
                rawValue: "computers", providedAnchor: nil, visibleAnchor: "section:mobile"
            ) == "setting:mobile:computers"
        )
    }
}

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
    }

    @Test(arguments: ["section:computers", "setting:computers:pair", "setting:mobile:computers"])
    func computersAnchorsResolveToTheMobileSubsection(anchor: String) {
        #expect(SettingsSectionID.mobile.canonicalNavigationAnchor(providedAnchor: anchor) == "setting:mobile:computers")
        #expect(SettingsSectionID.computers.canonicalNavigationAnchor(providedAnchor: anchor) == "setting:mobile:computers")
    }

    @Test(arguments: SettingsSectionID.allCases)
    func missingAnchorResolvesFromTheRequestedSection(section: SettingsSectionID) {
        let expected = section == .computers ? "setting:mobile:computers" : "section:\(section.rawValue)"
        #expect(section.canonicalNavigationAnchor(providedAnchor: nil) == expected)
    }

    @Test func explicitMobileRowAnchorIsPreserved() {
        #expect(SettingsSectionID.mobile.canonicalNavigationAnchor(providedAnchor: "setting:mobile:pairDevice") == "setting:mobile:pairDevice")
    }
}

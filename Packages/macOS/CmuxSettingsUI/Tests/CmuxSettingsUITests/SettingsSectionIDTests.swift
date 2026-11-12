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
    /// Cloud, so search ties and the detail stack follow the sidebar (#14771).
    @Test func devicesIsItsOwnSectionAfterCloud() {
        let cases = SettingsSectionID.allCases
        #expect(SettingsSectionID.computers.title == "Devices")
        #expect(SettingsSectionID(rawValue: "computers") == .computers)
        #expect(cases.firstIndex(of: .computers) == cases.firstIndex(of: .cloudMachines).map { $0 + 1 })
    }

    /// Anchors saved while Devices lived under Mobile select Devices and
    /// scroll to its header, whichever section the request named.
    @Test(arguments: [SettingsSectionID.mobile, .computers], ["setting:computers:pair", "setting:mobile:computers"])
    func legacyDevicesAnchorsLandOnTheDevicesHeader(target: SettingsSectionID, anchor: String) {
        let destination = target.navigationDestination(providedAnchor: anchor)
        #expect(destination.section == .computers)
        #expect(destination.anchorID == "section:computers")
    }

    @Test(arguments: SettingsSectionID.allCases)
    func missingAnchorLandsOnTheRequestedSectionHeader(section: SettingsSectionID) {
        let destination = section.navigationDestination(providedAnchor: nil)
        #expect(destination.section == section)
        #expect(destination.anchorID == "section:\(section.rawValue)")
    }

    @Test(arguments: [
        (SettingsSectionID.mobile, "setting:mobile:pairDevice"),
        (.computers, "setting:computers:discovery"),
        (.computers, "section:computers")
    ])
    func rowAnchorsArePreserved(section: SettingsSectionID, anchor: String) {
        let destination = section.navigationDestination(providedAnchor: anchor)
        #expect(destination.section == section)
        #expect(destination.anchorID == anchor)
    }

    @Test func notificationUserInfoResolvesTargetAndAnchor() throws {
        let legacy = try #require(SettingsSectionID.navigationDestination(userInfo: ["target": "mobile", "anchor": "setting:mobile:computers"]))
        #expect(legacy.section == .computers)
        #expect(legacy.anchorID == "section:computers")
        #expect(SettingsSectionID.navigationDestination(userInfo: ["target": "notASection"]) == nil)
        #expect(SettingsSectionID.navigationDestination(userInfo: nil) == nil)
    }
}

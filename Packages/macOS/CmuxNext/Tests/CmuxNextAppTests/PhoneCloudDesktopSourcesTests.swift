@testable import CmuxNextApp
import Testing

/// hostd's `surface` tabs: `c~<machine>~<team>` is a Cloud desktop, `s<n>` stays a phone tab.
struct PhoneCloudDesktopSourcesTests {
    @Test func onlyAWellFormedCloudDesktopTabRoutesToTheCloud() {
        #expect(PhoneCloudDesktopSources.target(of: "c~vm-1.a~team_1") == .init(machine: "vm-1.a", team: "team_1"))
        for tab in ["s12", "c~vm-1", "c~~team", "c~vm~", "c~vm~team~extra", "x~vm~team", "c.vm.team", ""] {
            #expect(PhoneCloudDesktopSources.target(of: tab) == nil, "\(tab)")
        }
    }
}

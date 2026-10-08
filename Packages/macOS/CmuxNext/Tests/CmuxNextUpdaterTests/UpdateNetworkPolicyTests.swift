import Testing
@testable import CmuxNextUpdater

/// R114 metered networks: downloads wait on Low Data Mode by default, also on
/// expensive links when asked, and never when the user turned them off.
@Suite struct UpdateNetworkPolicyTests {
    @Test func lowDataModeDefersByDefault() {
        #expect(UpdateNetworkPolicy.downloadsAutomatically(setting: true, mode: .deferLowData, constrained: false, expensive: true))
        #expect(!UpdateNetworkPolicy.downloadsAutomatically(setting: true, mode: .deferLowData, constrained: true, expensive: false))
    }

    @Test func expensiveLinksDeferWhenAsked() {
        #expect(!UpdateNetworkPolicy.downloadsAutomatically(setting: true, mode: .deferExpensive, constrained: false, expensive: true))
        #expect(!UpdateNetworkPolicy.downloadsAutomatically(setting: true, mode: .deferExpensive, constrained: true, expensive: false))
        #expect(UpdateNetworkPolicy.downloadsAutomatically(setting: true, mode: .deferExpensive, constrained: false, expensive: false))
    }

    @Test func downloadAlwaysAndTheOffSetting() {
        #expect(UpdateNetworkPolicy.downloadsAutomatically(setting: true, mode: .download, constrained: true, expensive: true))
        for mode in UpdateMeteredMode.allCases {
            #expect(!UpdateNetworkPolicy.downloadsAutomatically(setting: false, mode: mode, constrained: false, expensive: false))
        }
    }
}

import Testing
@testable import CmuxMobileShell

@Suite struct MobileSavedMacReconnectScopePolicyTests {
    private let policy = MobileSavedMacReconnectScopePolicy()

    @Test func presenceOutageAllowsUnknownActiveAndSecondaryMacs() {
        #expect(policy.isDialable(.unknownIdentity, isActiveMac: true, presenceLoaded: false))
        #expect(policy.isDialable(.unknownIdentity, isActiveMac: false, presenceLoaded: false))
    }

    @Test func loadedPresenceExcludesUnknownNonActiveMacsButKeepsActiveMacFailOpen() {
        #expect(policy.isDialable(.unknownIdentity, isActiveMac: true, presenceLoaded: true))
        #expect(!policy.isDialable(.unknownIdentity, isActiveMac: false, presenceLoaded: true))
    }

    @Test func refusedMacIsAlwaysExcluded() {
        #expect(!policy.isDialable(.refused, isActiveMac: true, presenceLoaded: false))
        #expect(!policy.isDialable(.refused, isActiveMac: false, presenceLoaded: false))
        #expect(!policy.isDialable(.refused, isActiveMac: true, presenceLoaded: true))
        #expect(!policy.isDialable(.refused, isActiveMac: false, presenceLoaded: true))
    }
}

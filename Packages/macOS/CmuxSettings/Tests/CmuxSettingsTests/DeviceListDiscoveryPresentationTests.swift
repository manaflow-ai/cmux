import Testing
@testable import CmuxSettings

@Suite("Device list discovery presentation")
struct DeviceListDiscoveryPresentationTests {
    @Test("An empty list still being discovered does not claim there are no Macs")
    func discoveringDoesNotClaimEmpty() {
        #expect(DeviceListDiscoveryPresentation.claim(
            deviceCount: 0,
            discoveryEnabled: true,
            phase: .discovering
        ) == .discovering)
    }

    @Test("A finished read with no Macs stays an empty result")
    func resolvedEmptyStaysEmpty() {
        #expect(DeviceListDiscoveryPresentation.claim(
            deviceCount: 0,
            discoveryEnabled: true,
            phase: .resolved
        ) == .empty)
    }

    @Test("A failed read with no rows reports the failure instead of an empty account")
    func unreachableDoesNotClaimEmpty() {
        #expect(DeviceListDiscoveryPresentation.claim(
            deviceCount: 0,
            discoveryEnabled: true,
            phase: .unreachable
        ) == .unreachable)
    }

    @Test("Rows replace the empty claim even if a later refresh is still running", arguments: [
        DeviceListDiscoveryPhase.discovering,
        .resolved,
        .unreachable,
    ])
    func listedDevicesHideTheEmptyClaim(phase: DeviceListDiscoveryPhase) {
        #expect(DeviceListDiscoveryPresentation.claim(
            deviceCount: 2,
            discoveryEnabled: true,
            phase: phase
        ) == .hidden)
    }

    @Test("Discovery turned off is not treated as a search in progress")
    func discoveryOffIsNotSearching() {
        #expect(DeviceListDiscoveryPresentation.claim(
            deviceCount: 0,
            discoveryEnabled: false,
            phase: .discovering
        ) == .empty)
    }
}

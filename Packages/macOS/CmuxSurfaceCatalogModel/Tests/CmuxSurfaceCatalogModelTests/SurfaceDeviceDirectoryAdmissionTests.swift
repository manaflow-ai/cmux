import Testing
@testable import CmuxSurfaceCatalogModel

struct SurfaceDeviceDirectoryAdmissionTests {
    @Test(arguments: [false, true])
    func authenticatedMembershipCannotBeRevivedByPresenceOrPairing(required: Bool) {
        let local = SurfaceDeviceInstanceID(deviceID: "local", tag: "test")
        let sameMac = SurfaceDeviceInstanceID(deviceID: "local", tag: "other")
        let host = SurfaceDeviceInstanceID(deviceID: "host", tag: "test")
        let hidden = SurfaceDeviceInstanceID(deviceID: "hidden", tag: "test")
        let policy = SurfaceDeviceDirectoryAdmission(requiresAuthenticatedDiscovery: required)
        let sources: [Set<SurfaceDeviceInstanceID>] = [[host, hidden], [hidden], [hidden], [hidden]]
        #expect(policy.admittedInstances(authenticated: [host, local, sameMac], legacySources: sources, local: local)
            == (required ? [host] : [host, hidden]))
        #expect(policy.admittedInstances(authenticated: [], legacySources: sources, local: local)
            == (required ? [] : [host, hidden]))
    }

    @Test("owner-proven account presence is admitted independently of the selected team")
    func accountOwnedPresenceIsAdmittedWhenAuthenticatedDirectoryIsTeamScoped() {
        let local = SurfaceDeviceInstanceID(deviceID: "local", tag: "test")
        let accountMac = SurfaceDeviceInstanceID(deviceID: "account-mac", tag: "test")
        let policy = SurfaceDeviceDirectoryAdmission(requiresAuthenticatedDiscovery: true)

        #expect(policy.admittedInstances(
            authenticated: [],
            accountOwned: [accountMac],
            legacySources: [],
            local: local
        ) == [accountMac])
    }
}

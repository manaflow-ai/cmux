import Testing
@testable import CmuxMobileCloud

@Suite struct CloudVPNRoutePolicyTests {
    @Test(arguments: ["10.0.0.0/8", "172.16.0.0/12", "192.168.1.0/24", "100.64.0.0/10", "fd7a:7570:6c6b::/48", "fd00::1/128"])
    func permitsPrivateCloudRoutes(_ cidr: String) { #expect(CloudVPNRoutePolicy.permits(cidr)) }

    @Test(arguments: ["0.0.0.0/0", "::/0", "0.0.0.0/1", "128.0.0.0/1", "8.8.8.8/32", "10.0.0.0/7", "172.16.0.0/8", "100.64.0.0/8", "fd00::/1", "fe80::/10", "10.1.1.1/33", "fd00::/129", "junk", "10.0.0.0/8/2"])
    func rejectsPublicOrMalformedRoutes(_ cidr: String) { #expect(!CloudVPNRoutePolicy.permits(cidr)) }
}

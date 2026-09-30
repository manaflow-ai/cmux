import Foundation
import Testing
@testable import CmuxMobileCloud

@Suite struct CloudNetworkPolicyTests {
    @Test func addsNormalizedDomains() throws {
        var policy = CloudNetworkPolicy(mode: .allowlist)

        try policy.addDomain(" HTTPS://API.Example.com/path ")

        #expect(policy.domains == ["api.example.com"])
    }

    @Test func rejectsInvalidOrDuplicateDomains() throws {
        var policy = CloudNetworkPolicy(mode: .allowlist, domains: ["api.example.com"])

        #expect(throws: CloudNetworkPolicyEditError.self) {
            try policy.addDomain("*.example.com")
        }
        #expect(throws: CloudNetworkPolicyEditError.self) {
            try policy.addDomain("api.example.com")
        }
    }

    @Test func normalizesRangesAndPortDefaults() throws {
        var policy = CloudNetworkPolicy(mode: .allowlist)

        try policy.addRange(CloudNetworkRange(
            cidr: " 203.0.113.5/24 ",
            port: 443,
            transport: nil,
            note: " HTTPS "
        ))

        #expect(policy.ranges == [
            CloudNetworkRange(cidr: "203.0.113.0/24", port: 443, transport: .tcp, note: "HTTPS")
        ])
        #expect(CloudNetworkPolicy.canonicalCIDR("2001:db8::1/64") == "2001:db8::/64")
    }

    @Test func rejectsInvalidRangesAndPorts() {
        var policy = CloudNetworkPolicy(mode: .allowlist)

        #expect(throws: CloudNetworkPolicyEditError.self) {
            try policy.addRange(CloudNetworkRange(cidr: "203.0.113.0/33"))
        }
        #expect(throws: CloudNetworkPolicyEditError.self) {
            try policy.addRange(CloudNetworkRange(cidr: "203.0.113.0/24", port: 65_536))
        }
    }

    @Test func allowlistHonorsRequiredDomainsAndPresets() {
        let preset = CloudNetworkPreset(
            id: "github",
            label: "GitHub",
            domains: ["github.com", "api.github.com"]
        )
        let catalog = CloudNetworkPresetCatalog(
            presets: [preset],
            requiredDomains: ["control.cmux.com"]
        )
        let allowlist = CloudNetworkPolicy(
            mode: .allowlist,
            domains: ["api.example.com"],
            presets: ["github"]
        )

        #expect(allowlist.allows("api.example.com", catalog: catalog))
        #expect(allowlist.allows("github.com", catalog: catalog))
        #expect(allowlist.allows("control.cmux.com", catalog: catalog))
        #expect(!allowlist.allows("example.com", catalog: catalog))
        #expect(CloudNetworkPolicy(mode: .none).allows("control.cmux.com", catalog: catalog))
        #expect(CloudNetworkPolicy(mode: .full).allows("example.com", catalog: catalog))
    }

    @Test func latestAgentUpdatesReportsBlockedHosts() {
        let catalog = CloudNetworkPresetCatalog(
            presets: [],
            requiredDomains: [],
            agentUpdateDomains: ["registry.npmjs.org", "releases.example.com"]
        )
        let policy = CloudNetworkPolicy(
            mode: .allowlist,
            domains: ["registry.npmjs.org"]
        )

        #expect(
            CloudAgentUpdates.latest.blockedDomains(for: policy, catalog: catalog)
                == ["releases.example.com"]
        )
        #expect(CloudAgentUpdates.image.blockedDomains(for: policy, catalog: catalog).isEmpty)
    }
}

import Foundation
import Testing
@testable import CmuxMobileContract

@Suite struct MobileMachineRowTests {
    private func makeRow(
        hostname: String?,
        ips: [String]
    ) -> MobileMachineRow {
        MobileMachineRow(
            teamId: "team",
            userId: "user",
            machineId: "machine-1",
            displayName: "Mac",
            tailscaleHostname: hostname,
            tailscaleIPs: ips,
            status: .online,
            lastSeenAt: 100,
            lastWorkspaceSyncAt: nil,
            wsPort: 9000,
            wsSecret: "secret"
        )
    }

    @Test func preferredAddressPrefersHostname() {
        let row = makeRow(hostname: "host.ts.net", ips: ["1.2.3.4"])
        #expect(row.preferredAddress == "host.ts.net")
        #expect(row.preferredServerID == "host.ts.net")
    }

    @Test func preferredAddressFallsBackToFirstIP() {
        let row = makeRow(hostname: "   ", ips: ["1.2.3.4", "5.6.7.8"])
        #expect(row.preferredAddress == "1.2.3.4")
        #expect(row.preferredServerID == "machine-1")
    }

    @Test func preferredAddressFallsBackToMachineID() {
        let row = makeRow(hostname: nil, ips: [])
        #expect(row.preferredAddress == "machine-1")
        #expect(row.preferredServerID == "machine-1")
    }

    @Test func codableRoundTrip() throws {
        let row = makeRow(hostname: "host.ts.net", ips: ["1.2.3.4"])
        let data = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(MobileMachineRow.self, from: data)
        #expect(decoded == row)
    }
}

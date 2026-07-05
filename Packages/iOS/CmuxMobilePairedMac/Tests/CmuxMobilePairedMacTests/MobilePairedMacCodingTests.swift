import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobilePairedMac

@Suite struct MobilePairedMacCodingTests {
    @Test func directCodingOmitsLocalAttachTicket() throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.10", port: 8443)
        )
        let mac = MobilePairedMac(
            macDeviceID: "mac-a",
            displayName: "Mac A",
            routes: [route],
            attachToken: "local-ticket-secret",
            attachTokenExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastSeenAt: Date(timeIntervalSince1970: 2_000),
            isActive: true,
            stackUserID: "user-1",
            teamID: "team-1"
        )

        let data = try JSONEncoder().encode(mac)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["attachToken"] == nil)
        #expect(object["attachTokenExpiresAt"] == nil)

        let decoded = try JSONDecoder().decode(MobilePairedMac.self, from: data)
        #expect(decoded.macDeviceID == "mac-a")
        #expect(decoded.attachToken == nil)
        #expect(decoded.attachTokenExpiresAt == nil)
    }
}

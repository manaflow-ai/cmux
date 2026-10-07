import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxNextMobile

/// `mobile.attach_ticket.create` for the iOS dogfood launcher: a Mac-scoped
/// ticket naming this Mac's v2 device and its irx EndpointID only, as a
/// pairing URL the target (physical device or simulator) decodes.
struct MobileAttachTicketTests {
    static let endpoint = String(repeating: "ab", count: 32)
    static let identity = MobileAttachTicket.HostIdentity(
        macDeviceID: "0B8A2F1E-5A51-4C55-9F0E-6E2F6A4F9C01", endpointID: endpoint, displayName: "Test Mac",
        userID: "user-1", appVersion: "0.1", appBuild: "7")

    @Test func physicalDeviceTicketIsAnIrohPairingURL() throws {
        let scheme = try #require(CmxPairingURLScheme(iOSBundleIdentifier: "dev.cmux.ios.nxfu"))
        let payload = try MobileAttachTicket.make(Self.identity, ttl: 600, target: .physicalDevice, scheme: scheme,
                                                  now: Date(timeIntervalSince1970: 1_000))
        #expect(payload.routes.map(\.kind) == [.iroh])
        let url = try #require(URLComponents(string: payload.attachURL))
        #expect(url.scheme == scheme.rawValue)
        let decoded = try CmxPairingQRCode().decode(url)
        #expect(decoded.macDeviceID == payload.ticket.macDeviceID)
        #expect(payload.ticket.macDeviceID.caseInsensitiveCompare(Self.identity.macDeviceID) == .orderedSame)
        guard case .peer(let peer, let hints)? = decoded.routes.first?.endpoint else {
            Issue.record("expected an iroh peer route")
            return
        }
        #expect(peer.endpointID == Self.endpoint)
        #expect(hints.isEmpty)
        let json = try #require(try JSONSerialization.jsonObject(with: payload.json()) as? [String: Any])
        #expect(json["attach_url"] as? String == payload.attachURL)
        let routes = (json["ticket"] as? [String: Any])?["routes"] as? [[String: Any]]
        #expect(routes?.first?["kind"] as? String == "iroh")
        #expect(json["expires_at"] != nil)
    }

    @Test func simulatorTicketUsesTheCompactPayload() throws {
        let scheme = try #require(CmxPairingURLScheme(iOSBundleIdentifier: "dev.cmux.ios.nxfu"))
        let payload = try MobileAttachTicket.make(Self.identity, ttl: 600, target: .simulatorInjection, scheme: scheme, now: Date())
        let url = try #require(URLComponents(string: payload.attachURL))
        #expect(url.host == "attach")
        #expect(url.queryItems?.contains { $0.name == "payload" } == true)
    }

    @Test func unknownTargetIsRejected() {
        #expect(MobileAttachTicket.Target(wireValue: "physical_device") == .physicalDevice)
        #expect(MobileAttachTicket.Target(wireValue: "carrier-pigeon") == nil)
    }
}

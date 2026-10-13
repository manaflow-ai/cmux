import CmuxWireGuardPairing
import Foundation
import Testing

@Suite struct PairingInvitationTests {
    @Test func linkRoundTrips() throws {
        let invitation = PairingInvitation(
            hostName: "Aziz's MacBook Pro", hostID: "host-1", hostKey: WireGuardKey().publicKey,
            endpoints: ["192.168.1.20:51888", "[fd7a:115c::1]:51888"], bootstrapKey: WireGuardKey(),
            bootstrapAddress: "10.77.1.7", presharedKey: WireGuardKey(randomPresharedKey: ()),
            hostAddress: "10.77.0.1", expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
        let link = invitation.link
        #expect(link.hasPrefix("cmux-next://pair#"))
        #expect(try PairingInvitation(link: link) == invitation)
        #expect(throws: PairingError.notAPairingLink) { try PairingInvitation(link: "https://example.com") }
    }

    @Test func keyMatchesWireGuardDerivation() throws {
        // RFC 7748 section 6.1 test vector (Alice).
        let privateKey = try #require(WireGuardKey(rawValue: Data(hex: "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")))
        #expect(privateKey.publicKey.hex == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
    }

    @Test func overlayPlanClassifiesAddresses() {
        let plan = OverlayPlan()
        #expect(plan.isDeviceAddress("10.77.0.2"))
        #expect(!plan.isDeviceAddress("10.77.0.1"))
        #expect(plan.isBootstrapAddress("10.77.1.9:5000"))
        #expect(!plan.isBootstrapAddress("10.77.0.9"))
    }

    @Test func pairedHostTriesLastGoodEndpointFirst() throws {
        let invitation = PairingInvitation(
            hostName: "Mac", hostID: "h", hostKey: WireGuardKey().publicKey, endpoints: ["a:1", "b:1", "c:1"],
            bootstrapKey: WireGuardKey(), bootstrapAddress: "10.77.1.1", presharedKey: WireGuardKey(randomPresharedKey: ()),
            hostAddress: "10.77.0.1", expiresAt: Date())
        var host = try PairedHost(invitation: invitation, response: EnrollmentResponse(
            address: "10.77.0.2", presharedKey: WireGuardKey(randomPresharedKey: ()), deviceID: "d"))
        host.lastGoodEndpoint = "b:1"
        #expect(host.endpointsToTry == ["b:1", "a:1", "c:1"])
    }
}

extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}

@Suite struct PairingCodeTests {
    @Test func parsesTypedVariants() throws {
        let code = try #require(PairingCode("ab0d-efgh"))
        #expect(code.description == "AB0D-EFGH")
        #expect(PairingCode("ABOD EFGH") == code)
        #expect(PairingCode("ABCD-EFG") == nil)
        #expect(PairingCode("ABCD-EFGU") == nil)
    }

    @Test func derivationIsStablePerHostAndDiffersAcrossHosts() {
        let code = PairingCode()
        let host = WireGuardKey().publicKey
        let first = code.derive(hostKey: host)
        let again = code.derive(hostKey: host)
        #expect(first.bootstrapKey == again.bootstrapKey && first.presharedKey == again.presharedKey)
        #expect((1...254).contains(first.addressIndex))
        #expect(code.derive(hostKey: WireGuardKey().publicKey).bootstrapKey != first.bootstrapKey)
        let invitation = PairingInvitation(code: code, hostName: "Mac", hostID: "h", hostKey: host, endpoints: [],
                                           expiresAt: Date())
        #expect(invitation.bootstrapKey == first.bootstrapKey)
        #expect(invitation.bootstrapAddress == "10.77.1.\(first.addressIndex)")
    }
}

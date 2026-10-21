@testable import CmuxVNCWebRTC
import Foundation
import Testing

struct PairingTests {
    @Test func linkRoundTrips() throws {
        let pairing = VNCPairing.generate(name: "Studio Mac")
        #expect(pairing.room.count == 32)
        #expect(pairing.secret.count >= 43)
        #expect(VNCPairing(link: pairing.link) == pairing)
    }

    @Test(arguments: [
        "cmux-vnc://pair?signal=http://x.dev&room=0123456789abcdef0123456789abcdef&secret=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "cmux-vnc://pair?signal=https://x.dev&room=short&secret=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "cmux-vnc://pair?signal=https://x.dev&room=0123456789abcdef0123456789abcdef&secret=short",
        "https://pair?x=1",
    ])
    func rejectsBadLinks(_ raw: String) {
        #expect(VNCPairing(link: URL(string: raw)!) == nil)
    }
}

struct RelayPreferenceTests {
    @Test func udpRelaysDropWhenStreamRelaysExist() {
        let servers = [ICEServerConfig(urls: ["stun:stun.cloudflare.com:3478", "turn:turn.cloudflare.com:3478?transport=udp",
                                              "turn:turn.cloudflare.com:3478?transport=tcp", "turns:turn.cloudflare.com:443?transport=tcp"],
                                       username: "u", credential: "c")]
        #expect(VNCPeerLink.preferringStreamRelays(servers).first?.urls == ["stun:stun.cloudflare.com:3478",
            "turn:turn.cloudflare.com:3478?transport=tcp", "turns:turn.cloudflare.com:443?transport=tcp"])
    }

    @Test func udpOnlyRelaysStay() {
        let servers = [ICEServerConfig(urls: ["turn:turn.example.com:3478?transport=udp"])]
        #expect(VNCPeerLink.preferringStreamRelays(servers).first?.urls == ["turn:turn.example.com:3478?transport=udp"])
    }
}

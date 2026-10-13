import CmuxVNCWebRTC
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

import Testing
@testable import CmuxVNC

struct CommonCryptoTests {
    @Test func portableDESMatchesCommonCrypto() {
        let challenge: [UInt8] = (0 ..< 16).map { UInt8(255 - $0 * 7) }
        for password in ["", "v", "password", "a🌍12345"] {
            var key = password.utf8.prefix(8).map(VNCPasswordAuthentication.reverseBits)
            key += Array(repeating: 0, count: 8 - key.count)
            #expect(RFBDES.encrypt(challenge: challenge, key: key) ==
                    VNCPasswordResponse(password: password, challenge: challenge).bytes)
        }
    }
}

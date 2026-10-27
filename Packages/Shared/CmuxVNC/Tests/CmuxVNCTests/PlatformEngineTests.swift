#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import CmuxVNC

/// The per-OS parts of the engine (CommonCrypto or swift-crypto with
/// `DESBlockCipher`; a pixel-buffer or a word-array frame) answer the same
/// vectors on every platform.
struct PlatformEngineTests {
    /// FIPS 46-3 worked example (key 133457799BBCDFF1).
    @Test func desKnownAnswer() {
        let cipher = CipherECB(algorithm: .des, key: hex("133457799bbcdff1"))
        #expect(cipher.encrypt(hex("0123456789abcdef")) == hex("85e813540f0ab405"))
        #expect(cipher.encrypt(hex("0123456789abcdef0123456789abcdef")) == hex("85e813540f0ab40585e813540f0ab405"))
    }

    /// FIPS 197 appendix C.1 (AES-128), two equal blocks to show ECB.
    @Test func aesKnownAnswer() {
        let cipher = CipherECB(algorithm: .aes128, key: hex("000102030405060708090a0b0c0d0e0f"))
        let block = hex("00112233445566778899aabbccddeeff")
        let expected = hex("69c4e0d86a7b0430d8cdb78070b4c55a")
        #expect(cipher.encrypt(block + block) == expected + expected)
    }

    @Test func cipherRefusesBadSizes() {
        #expect(CipherECB(algorithm: .des, key: hex("1334577999bbcd")).encrypt(hex("0123456789abcdef")) == nil)
        #expect(CipherECB(algorithm: .des, key: hex("133457799bbcdff1")).encrypt(hex("0123456789abcd")) == nil)
        #expect(CipherECB(algorithm: .aes128, key: hex("000102030405060708090a0b0c0d0e0f")).encrypt(hex("0011")) == nil)
    }

    /// A raw rectangle reaches the published frame: `withWords` reads the
    /// words the session decoded, whatever stores them.
    @Test func publishedFrameReadsDecodedWords() async throws {
        var server = Bytes()
        server.data += Array("RFB 003.008\n".utf8)
        server.u8(1); server.u8(1)
        server.u32(0)
        server.data += serverInit(width: 2, height: 2)
        server.u8(0); server.u8(0); server.u16(1)
        server.u16(1); server.u16(1); server.u16(1); server.u16(1); server.s32(RFBEncoding.raw.rawValue)
        server.data += [0x30, 0x20, 0x10, 0x00]
        let client = VNCClient(endpoint: VNCEndpoint(host: "scripted.invalid", port: 5900),
                               transport: ScriptedTransport(server.data))
        await client.connect()
        var frames = client.frames.makeAsyncIterator()
        let frame = try #require(await frames.next())
        #expect(frame.width == 2 && frame.height == 2 && frame.sequence == 1)
        #expect(frame.dirtyRect == CGRect(x: 1, y: 1, width: 1, height: 1))
        let words = frame.withWords { rowPixels, word in
            [word(0), word(1), word(rowPixels), word(rowPixels + 1)]
        }
        #expect(words == [0xFF00_0000, 0xFF00_0000, 0xFF00_0000, 0xFF10_2030])
        await client.disconnect()
    }
}

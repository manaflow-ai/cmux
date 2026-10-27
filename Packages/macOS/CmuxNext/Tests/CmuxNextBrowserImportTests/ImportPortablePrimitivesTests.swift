@testable import CmuxNextBrowserImport
import Foundation
import Testing

/// The primitives browser import keeps behind one interface so its parsers build on Linux (p15-oracle-139):
/// ``ImportCrypto`` (CommonCrypto on Apple platforms, swift-crypto on Linux), ``LZ4Block`` and ``RawDeflate``
/// (Compression on Apple platforms, Swift and zlib on Linux). Every expected value comes from a third
/// implementation (Python's hashlib, hmac and zlib, and the openssl CLI), so both platforms are held to the
/// same bytes.
struct ImportPortablePrimitivesTests {
    private func hex(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var rest = Substring(text)
        while let pair = rest.prefix(2).nilIfEmpty, let byte = UInt8(pair, radix: 16) {
            bytes.append(byte)
            rest = rest.dropFirst(2)
        }
        return bytes
    }

    private func bytes(_ secret: SecretBytes?) -> [UInt8]? {
        secret?.withUnsafeBytes { Array($0) }
    }

    // MARK: ImportCrypto

    @Test func pbkdf2MatchesChromiumsSafeStorageKey() {
        // python3 -c "hashlib.pbkdf2_hmac('sha1', b'peanuts', b'saltysalt', 1003, 16).hex()"
        let key = ImportCrypto.pbkdf2(.sha1, password: SecretBytes(copying: Array("peanuts".utf8)), salt: Array("saltysalt".utf8),
                                      rounds: 1003, keyLength: ImportCrypto.aes128KeySize)
        #expect(bytes(key) == hex("d9a09d499b4e1b7461f28e67972c6dbd"))
    }

    @Test func pbkdf2SHA256MatchesNSSKeyDerivation() {
        let key = ImportCrypto.pbkdf2(.sha256, password: SecretBytes(copying: Array("cmux".utf8)),
                                      salt: [UInt8](repeating: 0x22, count: 32), rounds: 1, keyLength: ImportCrypto.aes256KeySize)
        #expect(bytes(key) == hex("92a3d534d1be0d2474c58d1b4b7184af9f027e09e1b51d5ae90c0cb7e462ef22"))
    }

    @Test func pbkdf2RefusesZeroRoundsAndAnEmptyKey() {
        let password = SecretBytes(copying: Array("x".utf8))
        #expect(ImportCrypto.pbkdf2(.sha1, password: password, salt: [1], rounds: 0, keyLength: 16) == nil)
        #expect(ImportCrypto.pbkdf2(.sha1, password: password, salt: [1], rounds: 1, keyLength: 0) == nil)
    }

    @Test func aesCBCMatchesOpenSSLAndRoundTrips() throws {
        // printf 'cookie-value' | openssl enc -aes-128-cbc -K d9a0...6dbd -iv 2020...2020
        let key = SecretBytes(copying: hex("d9a09d499b4e1b7461f28e67972c6dbd"))
        let iv = [UInt8](repeating: 0x20, count: 16)
        let sealed = ImportCrypto.cbc(.encrypt, .aes, key: key, keyLength: 16, iv: iv, Array("cookie-value".utf8))
        #expect(bytes(sealed) == hex("91ad93c1f656dbad529c869b2c9beead"))
        let opened = ImportCrypto.cbc(.decrypt, .aes, key: key, keyLength: 16, iv: iv, hex("91ad93c1f656dbad529c869b2c9beead"))
        #expect(bytes(opened) == Array("cookie-value".utf8))
    }

    @Test func aesCBCRefusesCutBlocksBadPaddingAndShortKeys() {
        let key = SecretBytes(copying: hex("d9a09d499b4e1b7461f28e67972c6dbd"))
        let iv = [UInt8](repeating: 0x20, count: 16)
        let sealed = hex("91ad93c1f656dbad529c869b2c9beead")
        #expect(ImportCrypto.cbc(.decrypt, .aes, key: key, keyLength: 16, iv: iv, Array(sealed.dropLast())) == nil)
        #expect(ImportCrypto.cbc(.decrypt, .aes, key: key, keyLength: 16, iv: iv, []) == nil)
        #expect(ImportCrypto.cbc(.decrypt, .aes, key: key, keyLength: 32, iv: iv, sealed) == nil)
        #expect(ImportCrypto.cbc(.decrypt, .aes, key: key, keyLength: 16, iv: [0x20], sealed) == nil)
        #expect(ImportCrypto.cbc(.decrypt, .aes, key: ImportCrypto.noKey, keyLength: 16, iv: iv, sealed) == nil)
        // The wrong key leaves bytes whose padding does not check (this pair does not by chance).
        let wrong = SecretBytes(copying: [UInt8](repeating: 0x01, count: 16))
        #expect(ImportCrypto.cbc(.decrypt, .aes, key: wrong, keyLength: 16, iv: iv, sealed) == nil)
    }

    @Test func tripleDESMatchesOpenSSLWhereTheLibraryHasIt() {
        // printf 'cookie-value' | openssl enc -des-ede3-cbc -K 0001...1617 -iv 0001020304050607
        let key = SecretBytes(copying: Array(0..<24))
        let iv = Array<UInt8>(0..<8)
        let opened = ImportCrypto.cbc(.decrypt, .tripleDES, key: key, keyLength: 24, iv: iv, hex("20d84b2348036d9d04cd631372f14d2c"))
        if ImportCrypto.supports(.tripleDES) {
            #expect(bytes(opened) == Array("cookie-value".utf8))
        } else {
            #expect(opened == nil)
        }
    }

    @Test func sha1AndHMACReadPiecesInOrder() {
        let secret = SecretBytes(copying: Array("secret".utf8))
        // hashlib.sha1(b'abc' + b'secret')
        #expect(bytes(ImportCrypto.sha1([.bytes(Array("abc".utf8)), .secret(secret)])) == hex("de0a408ef519cd62e7379039634152874895c50c"))
        // hmac.new(b'key', b'prefix' + b'message', 'sha1')
        let mac = ImportCrypto.hmacSHA1(key: SecretBytes(copying: Array("key".utf8)),
                                        [.secret(SecretBytes(copying: Array("prefix".utf8))), .bytes(Array("message".utf8))])
        #expect(bytes(mac) == hex("89477621c1b8b6743253db1479d712abbb46d076"))
        #expect(ImportCrypto.sha256(Array(".example.com".utf8)) == hex("1496295b2be8c88d729a34163e6885b0470833c34e8b5b53c370a9f5dbb77009"))
    }

    @Test func chromiumCookieCryptoRoundTripsOnThePortableKey() throws {
        let crypto = ChromiumCookieCrypto(safeStoragePassword: Data("peanuts".utf8))
        let sealed = try crypto.encrypt("value", hostKey: ".example.com", databaseVersion: 24)
        #expect(try crypto.decrypt(sealed, hostKey: ".example.com", databaseVersion: 24) == "value")
        #expect(throws: ChromiumCookieCrypto.Failure.hostMismatch) {
            try crypto.decrypt(sealed, hostKey: ".other.com", databaseVersion: 24)
        }
        // The v10 body of an encrypt with no host hash is the openssl vector above.
        let plain = try crypto.encrypt("cookie-value", hostKey: "", databaseVersion: 0)
        #expect(Array(plain) == Array("v10".utf8) + hex("91ad93c1f656dbad529c869b2c9beead"))
    }

    // MARK: LZ4Block

    @Test func lz4DecodesAnOverlappingMatch() {
        // "abc", then a match of 12 at offset 3 (overlapping its own output), then the literals "XXXXX": a block
        // that follows lz4_Block_format.md (the last 5 bytes are literals, the last match starts 12 or more
        // bytes before the end), as lz4's reference encoder writes for mozLz4, so both decoders take it.
        let block: [UInt8] = [0x38] + Array("abc".utf8) + [3, 0] + [0x50] + Array("XXXXX".utf8)
        let expected = Array("abcabcabcabcabcXXXXX".utf8)
        #expect(LZ4Block.decodeInSwift(block, size: expected.count) == expected)
        #expect(LZ4Block.decode(block, size: expected.count) == expected)
    }

    @Test func lz4DecodesLongLiteralRuns() {
        let input = (0..<300).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let block = MozLz4Fixture.literalsOnly(input)
        #expect(LZ4Block.decodeInSwift(block, size: input.count) == input)
        #expect(LZ4Block.decode(block, size: input.count) == input)
    }

    @Test func lz4RefusesBadOffsetsAndWrongSizes() {
        let abc = Array("abc".utf8)
        #expect(LZ4Block.decodeInSwift([0x38] + abc + [0, 0] + [0x10, 0x58], size: 16) == nil)
        #expect(LZ4Block.decodeInSwift([0x38] + abc + [4, 0] + [0x10, 0x58], size: 16) == nil)
        #expect(LZ4Block.decodeInSwift([0x38] + abc + [3, 0] + [0x10, 0x58], size: 15) == nil)
        #expect(LZ4Block.decodeInSwift([0x38] + abc + [3, 0] + [0x10, 0x58], size: 17) == nil)
        #expect(LZ4Block.decodeInSwift([0x38] + abc + [3], size: 16) == nil)
        #expect(LZ4Block.decodeInSwift([0xF0, 255, 255], size: 1_000) == nil)
        #expect(LZ4Block.decode([], size: 1) == nil)
    }

    // MARK: RawDeflate

    @Test func rawDeflateInflatesAZipEntry() {
        // zlib.compressobj(9, zlib.DEFLATED, -15) of the text below.
        let stream: [UInt8] = [115, 202, 207, 207, 206, 77, 44, 202, 46, 214, 203, 40, 201, 205, 81, 112, 194, 199, 5, 0]
        let expected = Array("Bookmarks.html Bookmarks.html Bookmarks.html".utf8)
        #expect(inflate(stream, capacity: expected.count) == expected)
        // A cut stream gives fewer bytes than its entry's size (or none), which ExportArchive refuses.
        #expect(inflate(Array(stream.prefix(6)), capacity: expected.count) != expected)
        #expect(inflate([0xFF, 0xFF, 0xFF], capacity: 8) == nil)
    }

    private func inflate(_ stream: [UInt8], capacity: Int) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: capacity)
        let written = stream.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                // SAFETY: both buffers are lent for the call with their own counts.
                unsafe RawDeflate.inflate(input.baseAddress!, count: input.count, into: out.baseAddress!, capacity: out.count)
            }
        }
        return written.map { Array(output.prefix($0)) }
    }
}

extension Substring {
    fileprivate var nilIfEmpty: Substring? { isEmpty ? nil : self }
}

import Foundation
import Testing
@testable import CmuxNextMobile

/// Daemon lane bytes and compat ids (crash program phase 3): any chunking of
/// any bytes gives the same lines or the length refusal; any id text gives a
/// UUID string.
struct MobileLaneFuzzTests {
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    }

    @Test func lineSplitterGivesTheSameLinesForAnyChunking() {
        var rng = Rng(state: 0x1A_4E)
        for _ in 0..<1_000 {
            let bytes = Data((0..<rng.below(80)).map { _ in [0x0A, 0x61, 0x62, 0x0D][rng.below(4)] })
            var whole = LineSplitter(maximumLineBytes: 12)
            let expected = try? whole.append(bytes)
            var chunked = LineSplitter(maximumLineBytes: 12)
            var lines: [Data] = []
            var rest = bytes[...]
            var refused = false
            while !rest.isEmpty {
                let chunk = rest.prefix(1 + rng.below(9))
                rest = rest.dropFirst(chunk.count)
                do { lines += try chunked.append(Data(chunk)) } catch { refused = true; break }
            }
            if let expected, !refused {
                #expect(lines == expected)
                #expect(chunked.pendingByteCount == whole.pendingByteCount)
            }
        }
    }

    @Test func compatIDsAlwaysGiveUUIDStrings() {
        var rng = Rng(state: 0x1D)
        let alphabet = Array("0123456789abcdefABCDEF-_grp xé")
        for _ in 0..<2_000 {
            let text = String((0..<rng.below(40)).map { _ in alphabet[rng.below(alphabet.count)] })
            let hex = String((0..<32).map { _ in alphabet[rng.below(16)] })
            #expect(MobileCompatIDs.uuidString(fromHex: hex).flatMap(UUID.init(uuidString:)) != nil)
            _ = MobileCompatIDs.uuidString(fromHex: text)
            #expect(UUID(uuidString: MobileCompatIDs.nameBasedUUID(text)) != nil)
        }
        #expect(MobileCompatIDs.uuidString(fromHex: "0123456789abcdef0123456789ABCDEF") == "01234567-89AB-CDEF-0123-456789ABCDEF")
    }
}

import Foundation
import Testing
@testable import CmuxGit

/// Verifies the table-based hex encoder that replaced per-byte
/// `String(format: "%02x")` in the git index parser produces byte-identical
/// output. The replacement removed a process-global locale lock that turned
/// parallel git probes into a multi-core CPU storm
/// (https://github.com/manaflow-ai/cmux/issues/4639).
@Suite struct HexEncodingTests {
    @Test func matchesPrintfFormatForEveryByteValue() {
        for value in UInt8.min...UInt8.max {
            #expect(lowercaseHexString([value]) == String(format: "%02x", value))
        }
    }

    @Test func matchesPrintfFormatForObjectIDWidthSequence() {
        // 20 bytes is the SHA-1 object-ID width formatted per index entry,
        // the hot path in gitIndexSnapshot.
        let bytes: [UInt8] = (0..<20).map { UInt8(($0 * 37 + 5) & 0xff) }
        #expect(lowercaseHexString(bytes) == bytes.map { String(format: "%02x", $0) }.joined())
        #expect(lowercaseHexString(bytes).count == 40)
    }

    @Test func encodesEmptyCollectionAsEmptyString() {
        #expect(lowercaseHexString([UInt8]()) == "")
    }

    @Test func matchesPrintfFormatForArraySliceAndDataSuffix() {
        // The real call sites pass an ArraySlice (object ID / checksum) and a
        // Data.suffix (file signature); both must encode identically.
        let bytes: [UInt8] = [0x00, 0x0f, 0xa0, 0xff, 0x10, 0x01, 0x7e]
        let slice = bytes[1..<6]
        #expect(lowercaseHexString(slice) == slice.map { String(format: "%02x", $0) }.joined())
        let data = Data(bytes)
        #expect(
            lowercaseHexString(data.suffix(4))
                == data.suffix(4).map { String(format: "%02x", $0) }.joined()
        )
    }

    @Test func matchesPrintfFormatForUInt64BigEndianHash() {
        // The FNV content signature was %016llx of a UInt64; the replacement
        // encodes the 8 big-endian bytes and must match for full-width values.
        let values: [UInt64] = [0, 1, 0x0123_4567_89ab_cdef, .max, 0xff]
        for value in values {
            let bytes = (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * (7 - $0))) }
            #expect(lowercaseHexString(bytes) == String(format: "%016llx", CUnsignedLongLong(value)))
        }
    }
}

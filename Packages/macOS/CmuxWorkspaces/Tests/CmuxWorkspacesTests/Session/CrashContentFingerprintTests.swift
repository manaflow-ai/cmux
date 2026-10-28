import CryptoKit
import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("Exact bounded crash content")
struct CrashContentFingerprintTests {
    private struct Payload: Encodable {
        let title: String
        let content: Data
        let list: [String]
    }

    @Test("Same-length contents with equal ends and different middles stay distinct")
    func entireContentsMatter() throws {
        let prefix = String(repeating: "a", count: 20_000)
        let suffix = String(repeating: "z", count: 20_000)
        var fingerprints = CrashContentFingerprint()
        let result1 = fingerprints.fingerprint(prefix + "old" + suffix)
        let first = try #require(result1)
        let result2 = fingerprints.fingerprint(prefix + "new" + suffix)
        let second = try #require(result2)
        #expect(first != second)
        let result3 = fingerprints.fingerprint(Data((prefix + "old" + suffix).utf8))
        let dataA = try #require(result3)
        let result4 = fingerprints.fingerprint(Data((prefix + "new" + suffix).utf8))
        let dataB = try #require(result4)
        #expect(dataA != dataB)
    }

    @Test("Fingerprints equal the exact sorted-key JSON digest, including nested Data")
    func matchesJSONDigest() throws {
        let payload = Payload(title: "quoted\"\n/", content: Data(repeating: 255, count: 512), list: ["é", "\u{1}"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expected = Data(SHA256.hash(data: try encoder.encode(payload))).base64EncodedString()
        var fingerprints = CrashContentFingerprint()
        let result5 = fingerprints.fingerprint(payload)
        #expect(try #require(result5) == expected)
    }

    @Test("Escaped strings consume their encoded size, not only their UTF-8 size")
    func escapedSizeIsBounded() {
        var fingerprints = CrashContentFingerprint(maximumBytes: 100, maximumValueBytes: 20)
        let result6 = fingerprints.fingerprint(String(repeating: "\u{1}", count: 10))
        #expect(result6 == nil)
        let result7 = fingerprints.fingerprint("small")
        #expect(result7 == nil)
    }

    @Test("A complete array cannot bypass the single-value budget with small scalars")
    func compoundValueIsBounded() {
        var fingerprints = CrashContentFingerprint(maximumBytes: 1_000, maximumValueBytes: 32)
        let result8 = fingerprints.fingerprint(Array(repeating: "x", count: 50))
        #expect(result8 == nil)
    }

    @Test("Successive values consume one cumulative budget")
    func totalBudgetIsBounded() throws {
        var fingerprints = CrashContentFingerprint(maximumBytes: 20, maximumValueBytes: 20)
        let result9 = fingerprints.fingerprint("12345678")
        _ = try #require(result9)
        let result10 = fingerprints.fingerprint("12345678")
        _ = try #require(result10)
        let result11 = fingerprints.fingerprint("x")
        #expect(result11 == nil)
    }

    @Test("Copying the generator copies its remaining budget")
    func budgetHasValueSemantics() throws {
        var first = CrashContentFingerprint(maximumBytes: 10, maximumValueBytes: 10)
        var second = first
        let result12 = first.fingerprint("12345678")
        _ = try #require(result12)
        let result13 = second.fingerprint("12345678")
        _ = try #require(result13)
        let result14 = first.fingerprint("x")
        #expect(result14 == nil)
    }

    private struct Nested: Encodable {
        let depth: Int
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            if depth == 0 { try container.encode("leaf") }
            else { try container.encode(Nested(depth: depth - 1)) }
        }
    }

    @Test("Deep single-value wrapper chains fail before recursion can overflow")
    func nestingIsBounded() {
        var fingerprints = CrashContentFingerprint()
        let result15 = fingerprints.fingerprint(Nested(depth: 10_000))
        #expect(result15 == nil)
    }

    private struct Throwing: Encodable {
        enum Failure: Error { case expected }
        func encode(to encoder: any Encoder) throws { throw Failure.expected }
    }

    @Test("Invalid encodings and nonfinite numbers never become equality evidence")
    func errorsFailClosed() {
        var fingerprints = CrashContentFingerprint()
        let result16 = fingerprints.fingerprint(Throwing())
        #expect(result16 == nil)
        let result17 = fingerprints.fingerprint("after error")
        #expect(result17 == nil)
        var numbers = CrashContentFingerprint()
        let result18 = numbers.fingerprint(Double.nan)
        #expect(result18 == nil)
    }

    @Test("Nested Data is bounded before constructing its base64 string")
    func nestedDataIsBounded() {
        var fingerprints = CrashContentFingerprint(maximumBytes: 128, maximumValueBytes: 128)
        let payload = Payload(title: "a", content: Data(repeating: 255, count: 1_000_000), list: [])
        let result19 = fingerprints.fingerprint(payload)
        #expect(result19 == nil)
    }
}

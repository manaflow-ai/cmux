import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite struct AcpmuxCanonicalJSONTests {
    @Test func preservesUInt64DecimalSpelling() {
        let value: [String: Any] = ["n": UInt64.max]
        #expect(AcpmuxSecretKey.canonicalJSON(value) == "{\"n\":18446744073709551615}")
        #expect(AcpmuxSecretKey.canonicalDigest(value) != nil)
    }

    @Test func preservesNegativeZeroAsACanonicalNumber() {
        #expect(AcpmuxSecretKey.canonicalDigest(["z": -0.0]) != nil)
    }

    @Test func ordersKeysByUTF8BytesAndEscapesControls() {
        let value: [String: Any] = ["é": "\u{1}", "Which one?": "B", "a/b": [1, 2.0, true, NSNull()]]
        #expect(AcpmuxSecretKey.canonicalJSON(value) == "{\"Which one?\":\"B\",\"a/b\":[1,2,true,null],\"é\":\"\\u0001\"}")
    }

    @Test func rejectsFractionalAndOutOfRangeDoubles() {
        #expect(AcpmuxSecretKey.canonicalDigest(["q": 1.5]) == nil)
        #expect(AcpmuxSecretKey.canonicalDigest(["q": 1e15]) == nil)
    }

    @Test func boundsSerdeValueContainerDepth() {
        var accepted: Any = "leaf"
        for _ in 0..<126 { accepted = [accepted] }
        #expect(AcpmuxSecretKey.canonicalDigest(accepted) != nil)

        var rejected: Any = "leaf"
        for _ in 0..<127 { rejected = [rejected] }
        #expect(AcpmuxSecretKey.canonicalDigest(rejected) == nil)
    }
}

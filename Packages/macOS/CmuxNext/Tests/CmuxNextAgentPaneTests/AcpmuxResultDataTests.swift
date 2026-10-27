import Foundation
import Testing
@testable import CmuxNextAgentPane

/// p10-stability-167: a daemon result the harness and inventory calls cannot write back as JSON is an
/// ``AcpmuxRPCError`` named `acpmux.result_not_json`, the error those calls document, never the Objective-C
/// exception `JSONSerialization.data(withJSONObject:)` raises (the process ends) or a CmuxNextCompat error type.
struct AcpmuxResultDataTests {
    @Test func aResultJSONCannotHoldIsAnAcpmuxRPCError() throws {
        let error = #expect(throws: AcpmuxRPCError.self) {
            try AcpmuxRPCError.resultData(["checkedAt": Date()], of: "_acpmux/harnesses")
        }
        let refusal = try #require(error)
        #expect(refusal.name == AcpmuxRPCError.resultNotJSON)
        #expect(refusal.message.contains("_acpmux/harnesses"))
        #expect(!refusal.isUnreachable && !refusal.isMethodMissing)
    }

    @Test func aValidResultIsItsJSONBytes() throws {
        let data = try AcpmuxRPCError.resultData(["harnesses": ["claude"]], of: "_acpmux/harnesses")
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String]])
        #expect(object == ["harnesses": ["claude"]])
    }
}

@testable import CmuxMobileRPC
import Foundation
import Testing

/// The package's ``CheckedJSON`` and the request writer that goes through it (p10-stability-167):
/// a caller's params that JSON cannot hold throw instead of raising the Objective-C exception that
/// `JSONSerialization.data(withJSONObject:)` raises (uncatchable: the app ends).
@Suite struct CheckedJSONTests {
    @Test func requestDataWithAParamJSONCannotHoldThrows() {
        #expect(throws: CheckedJSONError.self) {
            try MobileCoreRPCClient.requestData(method: "workspace.list", params: ["since": Date()], id: "r1")
        }
        #expect(throws: CheckedJSONError.self) {
            try MobileCoreRPCClient.requestData(method: "workspace.list", params: ["ratio": Double.nan], id: "r2")
        }
    }

    @Test func requestDataWithValidParamsIsUnchanged() throws {
        let data = try MobileCoreRPCClient.requestData(method: "workspace.list", params: ["limit": 5], id: "r3")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["id"] as? String == "r3")
        #expect(object["method"] as? String == "workspace.list")
        #expect((object["params"] as? [String: Any])?["limit"] as? Int == 5)
    }

    @Test func aFragmentThrowsUnlessFragmentsAreAllowed() throws {
        // An event whose payload is a bare string: the old write raised "Invalid top-level type".
        #expect(throws: CheckedJSONError.invalidJSONObject(topLevelType: "String")) {
            try CheckedJSON.data(withJSONObject: "payload")
        }
        let fragment = try CheckedJSON.data(withJSONObject: "payload", options: [.fragmentsAllowed])
        #expect(String(decoding: fragment, as: UTF8.self) == #""payload""#)
    }
}

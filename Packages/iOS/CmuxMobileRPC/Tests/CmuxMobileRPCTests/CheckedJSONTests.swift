@testable import CmuxMobileRPC
import Foundation
import Testing

/// The package's ``CheckedJSON`` and the request writer that goes through it (p10-stability-167):
/// a caller's params that JSON cannot hold throw instead of raising the Objective-C exception that
/// `JSONSerialization.data(withJSONObject:)` raises (uncatchable: the app ends).
@Suite struct CheckedJSONTests {
    @Test func requestDataWithAParamJSONCannotHoldThrows() {
        #expect(throws: CheckedJSON.Failure.notAJSONObject) {
            try MobileCoreRPCClient.requestData(method: "workspace.list", params: ["since": Date()], id: "r1")
        }
        #expect(throws: CheckedJSON.Failure.notAJSONObject) {
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
        #expect(throws: CheckedJSON.Failure.notAJSONObject) { try CheckedJSON().data("payload") }
        #expect(throws: CheckedJSON.Failure.notAJSONObject) { try CheckedJSON().data(NSNull()) }
        let fragment = try CheckedJSON(options: [.fragmentsAllowed]).data("payload")
        #expect(String(decoding: fragment, as: UTF8.self) == #""payload""#)
        #expect(throws: CheckedJSON.Failure.notAJSONObject) {
            try CheckedJSON(options: [.fragmentsAllowed]).data(Double.nan)
        }
    }
}

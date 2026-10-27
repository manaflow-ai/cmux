@testable import CmuxNextCloud
import Foundation
import Testing

/// p10-stability-167: a request body JSON cannot hold is ``CloudAPIError/transport(_:)``, the error the Cloud
/// request path throws for every other failure before the send, never the Objective-C exception
/// `JSONSerialization.data(withJSONObject:)` raises (the process ends) or a CmuxNextCompat error type.
struct CloudAPIRequestBodyTests {
    @Test func aBodyJSONCannotHoldIsATransportError() async throws {
        let configuration = CloudConfiguration.resolve(
            bundleID: nil,
            bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
            process: [:],
            isDebugBuild: true
        )
        let api = CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { nil })
        let error = await #expect(throws: CloudAPIError.self) {
            try await api.send("POST", "/api/vm/body-check", body: ["at": Date()], as: CloudAPIClient.Ignored.self)
        }
        let failure = try #require(error)
        guard case .transport(let text) = failure else {
            Issue.record("expected a transport error, got \(failure)")
            return
        }
        #expect(text.hasPrefix("the request body is not JSON"))
    }

    @Test func requestBodyMapsEveryValueJSONCannotHold() throws {
        let bodies: [Any] = [["n": Double.nan], ["nested": [["d": Data([1])]]], "scalar"]
        for body in bodies {
            #expect(throws: CloudAPIError.self) { try CloudAPIError.requestBody(body) }
        }
        let data = try CloudAPIError.requestBody(["nonce": "n-1"])
        #expect(String(decoding: data, as: UTF8.self) == #"{"nonce":"n-1"}"#)
    }
}

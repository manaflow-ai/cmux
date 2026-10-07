import Foundation
import Testing
@testable import CmuxNextDaemon

/// `close-tabs` names why it closes (`close-reason-v1`): a browser session's end is sent as
/// `reason: "session_end"`, and a plain close sends no reason.
@Suite struct CloseReasonWireTests {
    private func object(_ request: CloseTabsRequest) throws -> [String: JSONValue] {
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: try WireCoding.encodeRequest(request, id: 1)) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    @Test func aSessionEndCloseNamesItsReason() throws {
        let ended = try object(CloseTabsRequest(surfaces: [4], endTerminals: false, mutation: nil, reason: .sessionEnd))
        #expect(ended["cmd"] == .string("close-tabs") && ended["reason"] == .string("session_end"))
        let plain = try object(CloseTabsRequest(surfaces: [4], endTerminals: false, mutation: nil))
        #expect(plain["reason"] == nil)
    }
}

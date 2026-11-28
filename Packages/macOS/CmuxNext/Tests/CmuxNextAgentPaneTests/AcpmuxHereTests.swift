import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AcpmuxHereTests {
    private func decode(_ json: String) throws -> AcpmuxHere {
        // Exercise the same JSONSerialization-to-Decodable boundary as the RPC client.
        let result = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try AcpmuxHere(result: result)
    }

    @Test func legacyReplyAndEmptyExchangeRemainDistinct() throws {
        #expect(try decode(#"{"here":[]}"#).sync == nil)
        #expect(try decode(#"{"here":[],"sync":[]}"#).sync == [])
    }

    @Test func acknowledgementDoesNotImplyConnectivity() throws {
        let result = try decode(#"{"here":[],"sync":[{"peer":"phone","connected":false,"acknowledged":true,"unacknowledgedEdits":0},{"peer":"mac","connected":true,"acknowledged":false,"unacknowledgedEdits":12}]}"#)
        let peers = try #require(result.sync)
        #expect(peers[0].peer == "phone")
        #expect(!peers[0].connected && peers[0].acknowledged)
        #expect(peers[1].connected && !peers[1].acknowledged)
        #expect(peers[1].unacknowledgedEdits == 12)
    }

    @Test func presenceKeepsDeviceAndActivityValues() throws {
        let result = try decode(#"{"here":[{"id":"owner","name":"Owner","kind":"person","status":"active","working":true,"devices":[{"device":"phone","deviceKind":"phone","status":"idle","working":false,"ageMs":42}]}]}"#)
        let member = try #require(result.here.first)
        #expect(member.id == "owner" && member.name == "Owner")
        #expect(member.kind == .person && member.status == .active && member.working)
        let device = try #require(member.devices.first)
        #expect(device.device == "phone" && device.deviceKind == .phone)
        #expect(device.status == .idle && !device.working && device.ageMs == 42)
    }

    @Test(arguments: ["-1", "1.5", "true", "\"2\"", "18446744073709551616"])
    func invalidCountsThrow(count: String) {
        #expect(throws: (any Error).self) {
            try decode("{\"here\":[],\"sync\":[{\"peer\":\"phone\",\"connected\":true,\"acknowledged\":false,\"unacknowledgedEdits\":\(count)}]}")
        }
    }

    @Test(arguments: [
        #"{}"#,
        #"{"here":[],"sync":{}}"#,
        #"{"here":[],"sync":[{"peer":"phone","connected":1,"acknowledged":false,"unacknowledgedEdits":0}]}"#,
        #"{"here":[],"sync":[{"peer":"phone","connected":true,"unacknowledgedEdits":0}]}"#,
        #"{"here":[{"id":"owner","name":"Owner","kind":"person","status":"active","working":false}]}"#,
    ])
    func incompleteOrWronglyTypedRepliesThrow(json: String) {
        #expect(throws: (any Error).self) { try decode(json) }
    }

    @Test func fullWidthEditCountSurvivesTransportBridge() throws {
        let result = try decode(#"{"here":[],"sync":[{"peer":"phone","connected":false,"acknowledged":false,"unacknowledgedEdits":18446744073709551615}]}"#)
        #expect(result.sync?.first?.unacknowledgedEdits == UInt64.max)
    }
}

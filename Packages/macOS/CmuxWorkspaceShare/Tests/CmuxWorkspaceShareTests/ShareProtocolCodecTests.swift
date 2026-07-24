import CmuxWorkspaceShare
import Foundation
import Testing

@Suite
struct ShareProtocolCodecTests {
    @Test
    func `Host hello preserves the TypeScript v1 envelope`() throws {
        let message = ShareHostMessage.hello(
            shared: [ShareSharedWorkspace(id: "workspace", title: "Demo")],
            layouts: [ShareWorkspaceLayout(ws: "workspace", tree: nil)]
        )

        let data = try JSONEncoder().encode(message)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["t"] as? String == "hello")
        #expect(object["proto"] as? Int == 1)
        #expect((object["shared"] as? [[String: Any]])?.first?["id"] as? String == "workspace")
        #expect((object["layouts"] as? [[String: Any]])?.first?["tree"] is NSNull)
        #expect(object["type"] == nil)
        #expect(object["payload"] == nil)
    }

    @Test
    func `Guest terminal messages decode with v1 field names`() throws {
        let input = Data(
            #"{"t":"guest-input","user":"u1","ws":"w1","pane":"p1","data":"ls\n"}"#.utf8
        )
        let subscription = Data(
            #"{"t":"guest-sub","ws":"w1","pane":"p1","count":2}"#.utf8
        )

        #expect(
            try JSONDecoder().decode(ShareServerMessage.self, from: input)
                == .guestInput(user: "u1", ws: "w1", pane: "p1", data: "ls\n")
        )
        #expect(
            try JSONDecoder().decode(ShareServerMessage.self, from: subscription)
                == .guestSub(ws: "w1", pane: "p1", count: 2)
        )
    }

    @Test
    func `Acknowledgement wire cases preserve exact v1 fields`() throws {
        let nonce = try #require(
            ShareAckNonce(rawValue: "8E35CBA0-B4D5-4CA0-8645-51CB6E2F869A")
        )
        let encoded = try JSONEncoder().encode(
            ShareHostMessage.ack(nonce: nonce)
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(object.count == 2)
        #expect(object["t"] as? String == "ack")
        #expect(object["nonce"] as? String == nonce.rawValue)

        let request = Data(
            #"{"t":"ack-request","nonce":"8E35CBA0-B4D5-4CA0-8645-51CB6E2F869A"}"#.utf8
        )
        #expect(
            try JSONDecoder().decode(ShareServerMessage.self, from: request)
                == .ackRequest(nonce: nonce)
        )
    }

    @Test
    func `Acknowledgement nonces enforce UTF-8 and Unicode control bounds`() throws {
        #expect(ShareAckNonce(rawValue: "a") != nil)
        #expect(ShareAckNonce(rawValue: String(repeating: "a", count: 64)) != nil)
        #expect(ShareAckNonce(rawValue: String(repeating: "é", count: 32)) != nil)
        #expect(ShareAckNonce(rawValue: "") == nil)
        #expect(ShareAckNonce(rawValue: String(repeating: "a", count: 65)) == nil)
        #expect(ShareAckNonce(rawValue: String(repeating: "é", count: 33)) == nil)
        #expect(ShareAckNonce(rawValue: "a\u{0000}b") == nil)
        #expect(ShareAckNonce(rawValue: "a\u{0085}b") == nil)

        let malformed = Data(#"{"t":"ack-request","nonce":"a\u0085b"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ShareServerMessage.self, from: malformed)
        }
    }

    @Test
    func `Removed browser and composer messages remain forward compatible`() throws {
        let removedMessage = Data(
            #"{"t":"guest-pointer","user":"u1","ws":"w1","pane":"p1"}"#.utf8
        )

        #expect(
            try JSONDecoder().decode(ShareServerMessage.self, from: removedMessage)
                == .unknown(type: "guest-pointer")
        )
    }

    @Test
    func `Binary terminal frame preserves the v1 header`() throws {
        let frame = try #require(
            ShareBinaryFrame.encode(
                kind: ShareProtocolConstants.binaryKindGrid,
                ws: "w",
                pane: "pane",
                payload: Data([0xAA, 0xBB])
            )
        )

        #expect(
            Array(frame)
                == [0x01, 0x01, 0x77, 0x04, 0x70, 0x61, 0x6E, 0x65, 0xAA, 0xBB]
        )
        let decoded = try #require(ShareBinaryFrame.decode(frame))
        #expect(decoded.kind == ShareProtocolConstants.binaryKindGrid)
        #expect(decoded.ws == "w")
        #expect(decoded.pane == "pane")
        #expect(decoded.payload == Data([0xAA, 0xBB]))
    }
}

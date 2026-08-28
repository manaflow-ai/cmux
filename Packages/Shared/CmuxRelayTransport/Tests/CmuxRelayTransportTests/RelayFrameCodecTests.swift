import Foundation
import Testing
@testable import CmuxRelayTransport

@Suite struct RelayFrameCodecTests {
    @Test func roundTripsSessionAndPayload() {
        let payload = Data([0x00, 0x01, 0xFA, 0xFF])
        let frame = RelayFrameCodec.encodeDataFrame(sessionID: 0xDEAD_BEEF, payload: payload)
        let decoded = RelayFrameCodec.decodeDataFrame(frame)
        #expect(decoded == RelayDataFrame(sessionID: 0xDEAD_BEEF, payload: payload))
    }

    @Test func decodesFromASliceWithNonZeroStartIndex() {
        // Data slices keep parent indices; the codec must not assume 0-based.
        let frame = RelayFrameCodec.encodeDataFrame(sessionID: 7, payload: Data([9, 8, 7]))
        var padded = Data([0xAA, 0xBB])
        padded.append(frame)
        let slice = padded.dropFirst(2)
        let decoded = RelayFrameCodec.decodeDataFrame(Data(slice))
        #expect(decoded?.sessionID == 7)
        #expect(decoded?.payload == Data([9, 8, 7]))
    }

    @Test func rejectsTruncatedUnknownAndOversized() {
        #expect(RelayFrameCodec.decodeDataFrame(Data([1, 0, 0])) == nil)
        var wrongType = RelayFrameCodec.encodeDataFrame(sessionID: 1, payload: Data([1]))
        wrongType[wrongType.startIndex] = 9
        #expect(RelayFrameCodec.decodeDataFrame(wrongType) == nil)
        let oversized = Data(count: RelayProtocol.dataHeaderBytes + RelayProtocol.maxDataPayloadBytes + 1)
        #expect(RelayFrameCodec.decodeDataFrame(oversized) == nil)
    }

    @Test func emptyPayloadIsLegal() {
        let decoded = RelayFrameCodec.decodeDataFrame(
            RelayFrameCodec.encodeDataFrame(sessionID: 3, payload: Data())
        )
        #expect(decoded == RelayDataFrame(sessionID: 3, payload: Data()))
    }

    @Test func channelPayloadSplitsBack() {
        let wrapped = RelayFrameCodec.channelPayload(channel: RelayProtocol.channelRPC, data: Data([5, 6]))
        let split = RelayFrameCodec.splitChannel(wrapped)
        #expect(split?.channel == RelayProtocol.channelRPC)
        #expect(split?.data == Data([5, 6]))
        #expect(RelayFrameCodec.splitChannel(Data()) == nil)
    }
}

@Suite struct RelayServerMessageDecodeTests {
    @Test func decodesEveryServerShape() throws {
        let welcome = #"{"t":"welcome","v":1,"role":"client","sessionId":4,"deadline":1700000000000,"hostPresent":true}"#
        guard case .welcome(let decoded)? = RelayServerMessage.decode(Data(welcome.utf8)) else {
            Issue.record("expected welcome")
            return
        }
        #expect(decoded.v == 1)
        #expect(decoded.role == .client)
        #expect(decoded.sessionId == 4)
        #expect(decoded.hostPresent)

        #expect(RelayServerMessage.decode(Data(#"{"t":"peer_joined","sessionId":2,"deviceId":"d"}"#.utf8)) != nil)
        #expect(RelayServerMessage.decode(Data(#"{"t":"peer_left","sessionId":2,"reason":"closed"}"#.utf8)) != nil)
        #expect(RelayServerMessage.decode(Data(#"{"t":"refresh_ack","deadline":5}"#.utf8)) != nil)
        #expect(RelayServerMessage.decode(Data(#"{"t":"bye","code":"expired","reason":""}"#.utf8)) != nil)
    }

    @Test func unknownTypeDecodesToNil() {
        #expect(RelayServerMessage.decode(Data(#"{"t":"upgrade_now"}"#.utf8)) == nil)
        #expect(RelayServerMessage.decode(Data("not json".utf8)) == nil)
    }

    @Test func clientMessagesEncodeWithDiscriminator() throws {
        let refresh = try JSONEncoder().encode(RelayRefresh(accessToken: "eyJ.a.b"))
        let object = try JSONSerialization.jsonObject(with: refresh) as? [String: Any]
        #expect(object?["t"] as? String == "refresh")
        #expect(object?["accessToken"] as? String == "eyJ.a.b")

        let closeSession = try JSONEncoder().encode(RelayCloseSession(sessionId: 9))
        let closeObject = try JSONSerialization.jsonObject(with: closeSession) as? [String: Any]
        #expect(closeObject?["t"] as? String == "close_session")
        #expect(closeObject?["sessionId"] as? Int == 9)
    }
}

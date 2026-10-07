import CmuxLink
@testable import CmuxLinkDirect
import Foundation
import Testing

@Suite("Direct wire")
struct WireTests {
    @Test("segments round-trip with their lane", arguments: [
        TransportLane.control,
        TransportLane(reliability: .unreliableUnordered, priority: .media),
        TransportLane(reliability: .partial(maxLifetime: .milliseconds(250)), priority: .render),
        TransportLane(reliability: .reliableOrdered, priority: .bulk),
    ])
    func segmentRoundTrip(_ lane: TransportLane) throws {
        let record = DirectRecord.segment(more: true, lane: lane, bytes: Data("payload".utf8))
        #expect(try DirectRecord(decoding: record.encoded()) == record)
    }

    @Test("close round-trips; unknown types and bad lanes are refused")
    func closeAndErrors() throws {
        #expect(try DirectRecord(decoding: DirectRecord.close.encoded()) == .close)
        #expect(throws: DirectWireError.unknownRecordType(9)) { try DirectRecord(decoding: Data([9])) }
        #expect(throws: DirectWireError.truncated) { try DirectRecord(decoding: Data([1, 0, 0])) }
        #expect(throws: DirectWireError.unknownReliability(7)) { try DirectRecord(decoding: Data([1, 0, 7, 0, 0, 0, 0, 0])) }
        #expect(throws: DirectWireError.unknownPriority(9)) { try DirectRecord(decoding: Data([1, 0, 0, 9, 0, 0, 0, 0])) }
        #expect(throws: DirectWireError.truncated) { try DirectRecord(decoding: Data()) }
    }

    @Test("a large frame splits into records that fit Noise and reassemble in order")
    func segmentation() throws {
        let bytes = Data((0..<(200 * 1024)).map { UInt8(truncatingIfNeeded: $0 * 31) })
        let records = DirectRecord.segments(of: TransportFrame(lane: .control, bytes: bytes))
        #expect(records.count == 4)
        var joined = Data()
        for (index, record) in records.enumerated() {
            let encoded = record.encoded()
            #expect(encoded.count <= DirectRecord.maxPlaintext)
            guard case let .segment(more, _, piece) = try DirectRecord(decoding: encoded) else {
                Issue.record("not a segment")
                return
            }
            #expect(more == (index < records.count - 1))
            joined.append(piece)
        }
        #expect(joined == bytes)
        #expect(DirectRecord.segments(of: TransportFrame(lane: .control, bytes: Data())).count == 1)
    }

    @Test("handshake payloads carry the host id and version")
    func handshakePayload() throws {
        let hello = DirectHandshakePayload(hostID: "mac-studio")
        #expect(try DirectHandshakePayload(decoding: hello.encoded(), expectsHostID: true) == hello)
        #expect(try DirectHandshakePayload(decoding: Data([1]), expectsHostID: false).hostID == nil)
        #expect(throws: DirectWireError.unsupportedVersion(2)) {
            try DirectHandshakePayload(decoding: Data([2]), expectsHostID: false)
        }
        #expect(throws: DirectWireError.truncated) {
            try DirectHandshakePayload(decoding: Data([1, 5, 0, 65]), expectsHostID: true)
        }
    }

    @Test("public keys parse from standard and URL-safe base64")
    func publicKeyParsing() throws {
        let key = DirectIdentity().publicKey
        #expect(DirectPublicKey(base64: key.base64) == key)
        let urlSafe = key.base64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(DirectPublicKey(base64: urlSafe) == key)
        #expect(DirectPublicKey(base64: "AAAA") == nil)
        #expect(DirectPublicKey(base64: "not base64!") == nil)
        let restored = try DirectIdentity(privateKeyRepresentation: DirectIdentity().privateKeyRepresentation)
        #expect(restored.publicKey.rawRepresentation.count == 32)
    }

    @Test("hints round-trip through the resolver")
    func hints() async throws {
        let resolver = DirectHintsResolver()
        let endpoint = DirectEndpoint(address: try #require(DirectAddress("100.100.1.2")), port: 4999, hostKey: DirectIdentity().publicKey)
        let peer = LinkPeer(hostID: "h", hints: resolver.hints(for: endpoint))
        #expect(await resolver.endpoints(for: peer) == [endpoint])
        #expect(await resolver.endpoints(for: LinkPeer(hostID: "h")) == [])
        let noPort = LinkPeer(hostID: "h", hints: ["direct.address": "studio.local", "direct.hostKey": endpoint.hostKey.base64])
        guard case let .address(_, port)? = await resolver.endpoints(for: noPort).first?.target else {
            Issue.record("no endpoint")
            return
        }
        #expect(port == DirectEndpoint.defaultPort)
    }
}

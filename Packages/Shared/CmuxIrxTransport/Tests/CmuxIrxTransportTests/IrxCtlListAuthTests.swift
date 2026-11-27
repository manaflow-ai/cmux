import Foundation
import Testing

@testable import CmuxIrxTransport

/// List-auth control-plane wire additions: the ack frame shape, the directory
/// overlay with and without the new fields, and the freshness stamps.
@Suite("control plane list-auth wire")
struct IrxCtlListAuthWireTests {
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let iso = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = iso.date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "unparseable date: \(raw)"))
            }
            return date
        }
        return decoder
    }()

    @Test func ackFrameShape() throws {
        let data = try IrxControlPlaneClient.encodedAck(
            rev: 42, appliedAt: Date(timeIntervalSince1970: 1_787_000_000))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["v"] as? Int == 1)
        #expect(object?["type"] as? String == "ack")
        #expect(object?["rev"] as? Int == 42)
        let payload = object?["payload"] as? [String: Any]
        // RFC3339 applied stamp, per the ack fixture.
        let appliedAt = try #require(payload?["appliedAt"] as? String)
        #expect(appliedAt.hasSuffix("Z"))
        #expect(ISO8601DateFormatter().date(from: appliedAt) != nil)
    }

    @Test func ackMatchesTheCheckedInFixtureShape() throws {
        // Decode the schema agent's fixture with the generated model, then
        // confirm our emitter round-trips through the same generated type.
        let fixturesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("schemas/control-plane/fixtures")
        let fixture = try Data(
            contentsOf: fixturesDirectory.appendingPathComponent("ack.json"))
        let decoded = try Self.decoder.decode(CTLACK.self, from: fixture)
        #expect(decoded.rev == 42)
        let emitted = try IrxControlPlaneClient.encodedAck(rev: 42)
        let reDecoded = try Self.decoder.decode(CTLACK.self, from: emitted)
        #expect(reDecoded.rev == decoded.rev)
        #expect(reDecoded.type == .ack)
    }

    @Test func directoryOverlayDecodesNewFields() throws {
        let json = Data(
            """
            {
              "v": 1, "type": "directory", "rev": 7,
              "payload": {
                "issuedAt": "2026-08-29T10:00:00Z",
                "ttlSeconds": 86400,
                "minimumSupportedVersion": {"mac": "1.2.0", "ios": "1.1.0"},
                "routeContractVersion": 1,
                "relayFleet": ["https://usw1.relay.cmux.dev/"],
                "grantVerificationKeys": [],
                "bindings": [
                  {
                    "bindingId": "b-1",
                    "clientNamespace": "com.cmuxterm.app",
                    "deviceId": "d-1",
                    "endpointId": "aabb",
                    "homeRelayUrl": "https://usw1.relay.cmux.dev/",
                    "instanceTag": "default",
                    "status": "seeded",
                    "revoked": false,
                    "appVersion": "1.2.3+456",
                    "releaseTrack": "stable",
                    "capabilities": ["cmux.irx.v2", "list-auth"],
                    "lastConfirmedAt": "2026-08-29T09:00:00Z"
                  }
                ]
              }
            }
            """.utf8)
        let fact = try Self.decoder.decode(IrxCtlDirectoryFact.self, from: json)
        #expect(fact.rev == 7)
        #expect(fact.payload.ttlSeconds == 86_400)
        #expect(fact.payload.issuedAt != nil)
        #expect(fact.payload.minimumSupportedVersion?.mac == "1.2.0")
        let entry = try #require(fact.payload.bindings.first)
        #expect(entry.endpointID == "aabb")
        #expect(entry.status == "seeded")
        #expect(entry.revoked == false)
        #expect(entry.capabilities == ["cmux.irx.v2", "list-auth"])

        let snapshot = IrxDeviceListSnapshot(
            fact: fact, receivedAtWall: Date(), receivedAtMonotonic: .now)
        #expect(snapshot.rev == 7)
        #expect(snapshot.entries["aabb"]?.status == "seeded")
        #expect(snapshot.entries["aabb"]?.deviceID == "d-1")
        #expect(snapshot.entries["aabb"]?.bindingID == "b-1")
    }

    @Test func directoryOverlayToleratesAbsentNewFields() throws {
        // A pre-list-auth server's directory: no issuedAt/ttl/status/revoked.
        let json = Data(
            """
            {
              "v": 1, "type": "directory", "rev": 3,
              "payload": {
                "routeContractVersion": 1,
                "relayFleet": [],
                "grantVerificationKeys": [],
                "bindings": [
                  {
                    "bindingId": "b-1",
                    "clientNamespace": "com.cmuxterm.app",
                    "endpointId": "ccdd"
                  }
                ]
              }
            }
            """.utf8)
        let fact = try Self.decoder.decode(IrxCtlDirectoryFact.self, from: json)
        #expect(fact.payload.issuedAt == nil)
        #expect(fact.payload.ttlSeconds == nil)
        let wall = Date()
        let snapshot = IrxDeviceListSnapshot(
            fact: fact, receivedAtWall: wall, receivedAtMonotonic: .now)
        // Defensive defaults: presence in the account directory authorizes,
        // the receipt stands in for the missing stamp, TTL falls back to a day.
        #expect(snapshot.entries["ccdd"]?.status == "active")
        #expect(snapshot.entries["ccdd"]?.revoked == false)
        #expect(snapshot.issuedAt == wall)
        #expect(snapshot.ttlSeconds == IrxDeviceListSnapshot.defaultTTLSeconds)
    }

    @Test func legacyDirectoryPayloadPreservesOldFrameFields() throws {
        let json = Data(
            """
            {
              "v": 1, "type": "directory", "rev": 3,
              "payload": {
                "routeContractVersion": 1,
                "relayFleet": ["https://usw1.relay.cmux.dev/"],
                "grantVerificationKeys": [{"alg":"EdDSA","keyId":"k1","publicKey":"pk1"}],
                "bindings": [{
                  "bindingId": "b-1",
                  "clientNamespace": "com.cmuxterm.app",
                  "deviceId": "d-1",
                  "endpointId": "ccdd",
                  "homeRelayUrl": "https://usw1.relay.cmux.dev/"
                }]
              }
            }
            """.utf8)
        let fact = try Self.decoder.decode(IrxCtlDirectoryFact.self, from: json)
        let receivedAt = Date(timeIntervalSince1970: 1_787_000_000)
        let payload = IrxControlPlaneClient.legacyDirectoryPayload(
            from: fact, receivedAt: receivedAt)
        #expect(payload.bindings.count == 1)
        #expect(payload.bindings[0].bindingID == "b-1")
        #expect(payload.bindings[0].clientNamespace == "com.cmuxterm.app")
        #expect(payload.bindings[0].homeRelayURL == "https://usw1.relay.cmux.dev/")
        #expect(payload.grantVerificationKeys.count == 1)
        #expect(payload.relayFleet == ["https://usw1.relay.cmux.dev/"])
        #expect(payload.issuedAt == receivedAt)
        #expect(payload.ttlSeconds == IrxDeviceListSnapshot.defaultTTLSeconds)
    }

    @Test func currentFrameStampDecodesFromPayloadOrTopLevel() throws {
        let inPayload = Data(
            #"{"v":1,"type":"current","rev":9,"payload":{"issuedAt":"2026-08-29T10:00:00Z"}}"#
                .utf8)
        let payloadStamp = try Self.decoder.decode(IrxCtlFreshnessStamp.self, from: inPayload)
        #expect(payloadStamp.rev == 9)
        #expect(payloadStamp.issuedAt != nil)

        let topLevel = Data(
            #"{"v":1,"type":"current","rev":10,"issuedAt":"2026-08-29T10:00:00Z"}"#.utf8)
        let topStamp = try Self.decoder.decode(IrxCtlFreshnessStamp.self, from: topLevel)
        #expect(topStamp.rev == 10)
        #expect(topStamp.issuedAt != nil)
    }

    @Test func snapshotCompleteWithoutStampDecodesStampless() throws {
        let json = Data(
            #"{"v":1,"type":"snapshot_complete","rev":11,"payload":{}}"#.utf8)
        let stamp = try Self.decoder.decode(IrxCtlFreshnessStamp.self, from: json)
        #expect(stamp.rev == 11)
        #expect(stamp.issuedAt == nil)
    }

    @Test func helloV2CarriesClientInfoAndOmitsItWhenAbsent() throws {
        let bare = try JSONEncoder().encode(
            IrxCtlHelloV2(
                endpointID: "aabb", haveRev: nil, wantPasses: false, clientInfo: nil))
        let bareObject =
            try JSONSerialization.jsonObject(with: bare) as? [String: Any]
        let barePayload = bareObject?["payload"] as? [String: Any]
        #expect(bareObject?["type"] as? String == "hello")
        #expect(barePayload?["endpointId"] as? String == "aabb")
        #expect(barePayload?["platform"] == nil)

        let info = IrxCtlClientInfo(
            deviceID: "d-1",
            platform: "mac",
            appVersion: "1.2.3+456",
            releaseTrack: "stable",
            capabilities: ["cmux.irx.v2", "list-auth"]
        )
        let full = try JSONEncoder().encode(
            IrxCtlHelloV2(
                endpointID: "aabb", haveRev: 5, wantPasses: true, clientInfo: info))
        let fullObject =
            try JSONSerialization.jsonObject(with: full) as? [String: Any]
        let payload = fullObject?["payload"] as? [String: Any]
        #expect(payload?["haveRev"] as? Int == 5)
        #expect(payload?["deviceId"] as? String == "d-1")
        #expect(payload?["platform"] as? String == "mac")
        #expect(payload?["releaseTrack"] as? String == "stable")
        #expect((payload?["capabilities"] as? [String]) == ["cmux.irx.v2", "list-auth"])
    }

    @Test func helloAckOverlayToleratesOldAndNewShapes() throws {
        let old = Data(
            #"{"v":1,"type":"hello_ack","payload":{"sessionId":"s-1","resumedFromRev":null}}"#
                .utf8)
        let oldOverlay = try Self.decoder.decode(IrxCtlHelloAckOverlay.self, from: old)
        #expect(oldOverlay.payload?.serverCapabilities == nil)

        let new = Data(
            """
            {"v":1,"type":"hello_ack","payload":{
              "sessionId":"s-2","resumedFromRev":4,
              "serverCapabilities":["list-auth"],
              "minimumSupportedVersion":{"ios":"1.0.0"}
            }}
            """.utf8)
        let newOverlay = try Self.decoder.decode(IrxCtlHelloAckOverlay.self, from: new)
        #expect(newOverlay.payload?.serverCapabilities == ["list-auth"])
        #expect(newOverlay.payload?.minimumSupportedVersion?.ios == "1.0.0")
    }
}

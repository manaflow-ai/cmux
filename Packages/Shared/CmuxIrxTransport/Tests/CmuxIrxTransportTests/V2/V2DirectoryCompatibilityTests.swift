import Foundation
import Testing
@testable import CmuxIrxTransport

struct V2DirectoryCompatibilityTests {
    @Test func stableDirectoryDecoderIgnoresRulesAndPreservesPhonePermission() throws {
        let wire = Data(#"""
        {
          "devices": [],
          "inboundPeers": [{
            "device": {
              "descriptor": {
                "identity": {"environment":"production","projectId":"project","teamId":"team",
                  "userId":"owner","deviceId":"phone","appNamespace":"dev.cmux.app","buildTag":"default"},
                "endpointId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "identityGeneration":0,
                "metadata":{"platform":"ios","displayName":"Phone","appVersion":"0.64.25",
                  "pairingEnabled":true,"capabilities":["irx-v2"],"relayURLs":[]}
              },
              "deviceRecordId":"phone-record","revision":4,"revoked":false
            },
            "permissionExpiresAt":2000
          }],
          "issuedAt":1000,"nextCursor":null,"permissionExpiresAt":1900,
          "relayURLs":[],"revision":4,"teamId":"team",
          "rules":["cmux.mac-peer-inbound.v1"]
        }
        """#.utf8)
        let old = try JSONDecoder().decode(V06425Directory.self, from: wire)
        let current = try JSONDecoder().decode(V2Directory.self, from: wire)
        #expect(old.inboundPeers == current.inboundPeers)
        #expect(old.inboundPeers?.first?.device.descriptor.metadata.platform == .ios)
        #expect(old.inboundPeers?.first?.permissionExpiresAt == 2000)
        #expect(old.permissionExpiresAt == 1900)
        #expect(current.rules == ["cmux.mac-peer-inbound.v1"])

        // The new decoder still accepts the old server/cached representation.
        let oldWire = try JSONEncoder().encode(old)
        let upgraded = try JSONDecoder().decode(V2Directory.self, from: oldWire)
        #expect(upgraded.rules == nil)
        #expect(upgraded.inboundPeers == current.inboundPeers)
        #expect(upgraded.devices == current.devices)
        #expect(upgraded.revision == current.revision)
        #expect(upgraded.permissionExpiresAt == current.permissionExpiresAt)
    }
}

/// Frozen directory decoder shape from v0.64.25 (b685a275c2).
/// Nested device/permission wire models are unchanged by this PR.
private struct V06425Directory: Codable {
    let devices: [V2DeviceRecord]
    let inboundPeers: [V2InboundPeerPermission]?
    let issuedAt: Int
    let nextCursor: String?
    let permissionExpiresAt: Int
    let relayURLs: [String]
    let revision: Int
    let teamID: String

    enum CodingKeys: String, CodingKey {
        case devices, inboundPeers, issuedAt, nextCursor, permissionExpiresAt, relayURLs, revision
        case teamID = "teamId"
    }
}

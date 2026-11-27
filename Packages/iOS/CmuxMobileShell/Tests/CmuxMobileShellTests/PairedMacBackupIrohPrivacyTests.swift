import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

private let irohBackupRouteDisclosureDate = Date(timeIntervalSince1970: 2_000_000_000)

@Suite struct PairedMacBackupIrohPrivacyTests {
    private func encodedRecordObject(from op: PairedMacBackupOp) throws -> [String: Any] {
        let body = PairedMacBackupRequestBody(ops: [PairedMacBackupOpWire(
            op: op,
            routeDisclosureDate: irohBackupRouteDisclosureDate
        )])
        let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(body)) as? [String: Any]
        let ops = try #require(json?["ops"] as? [[String: Any]])
        let first = try #require(ops.first)
        return try #require(first["record"] as? [String: Any])
    }

    @Test func pairedMacCloudBackupNeverCarriesPrivateIrohHints() throws {
        let now = Date()
        let privateAddress = "100.64.1.2:49152"
        let publicAddress = "8.8.8.8:49152"
        let route = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "a", count: 64)
                ),
                pathHints: [
                    try CmxIrohPathHint(
                        kind: .directAddress,
                        value: privateAddress,
                        source: .tailscale,
                        privacyScope: .privateNetwork,
                        observedAt: now,
                        expiresAt: now.addingTimeInterval(300),
                        networkProfile: CmxIrohNetworkProfileKey(
                            source: .tailscale,
                            profileID: String(repeating: "a", count: 64)
                        )
                    ),
                    try CmxIrohPathHint(
                        kind: .relayURL,
                        value: "https://relay.example.test/",
                        source: .native,
                        privacyScope: .publicInternet
                    ),
                    try CmxIrohPathHint(
                        kind: .directAddress,
                        value: publicAddress,
                        source: .native,
                        privacyScope: .publicInternet
                    ),
                ]
            )
        )
        let mac = MobilePairedMac(
            macDeviceID: "mac-a",
            displayName: "A",
            routes: [route],
            createdAt: now,
            lastSeenAt: now,
            isActive: true,
            stackUserID: "user-1"
        )

        let record = BackingUpPairedMacStore.backupRecord(from: mac)
        guard case let .peer(_, hints) = record.routes.first?.endpoint else {
            Issue.record("Expected backed-up Iroh peer route")
            return
        }
        #expect(hints.count == 1)
        #expect(hints.first?.kind == .relayURL)

        let object = try encodedRecordObject(from: .upsert(record))
        let encoded = try JSONSerialization.data(withJSONObject: object)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains(privateAddress))
        #expect(!json.contains(publicAddress))
        #expect(!json.contains("production"))
    }
    @Test func deleteUploadHasNoRecordBody() throws {
        let body = PairedMacBackupRequestBody(ops: [PairedMacBackupOpWire(
            op: .delete(macDeviceID: "mac-a"),
            routeDisclosureDate: irohBackupRouteDisclosureDate
        )])
        let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(body)) as? [String: Any]
        let ops = try #require(json?["ops"] as? [[String: Any]])
        let first = try #require(ops.first)
        #expect(first["record"] == nil)
        #expect(first["deleted"] as? Bool == true)
    }
}

import CMUXMobileCore
import Foundation
import SQLite3
import Testing
@testable import CmuxMobilePairedMac

/// The Tailscale Only method folded into Direct (schema v13).
@Suite struct MobilePairedMacTailscaleOnlyMigrationTests {
    private let tailscale = try! CmxAttachRoute(
        id: "tailscale", kind: .tailscale, endpoint: .hostPort(host: "100.64.0.9", port: 58465))
    private let iroh = try! CmxAttachRoute(
        id: "iroh", kind: .iroh,
        endpoint: .peer(identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)), pathHints: []))

    @Test func tailscaleOnlyPairingsBecomeDirectOrReturnToIroh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paired-macs.sqlite3")
        let now = Date(timeIntervalSince1970: 1_000)

        let store = try MobilePairedMacStore(databaseURL: url)
        // Knows the Mac's device key: keeps its LAN address and gains Tailscale.
        try await store.upsert(macDeviceID: "keyed-mac", displayName: "Keyed", routes: [iroh, tailscale],
                               instanceTag: "default", markActive: true, stackUserID: "alice", now: now)
        try await store.setDirectAddresses(macDeviceID: "keyed-mac", instanceTag: "default",
                                           rawJSON: "[{\"address\":\"192.168.1.10\",\"port\":58465,\"enabled\":true},{\"address\":\"100.64.0.9\",\"port\":58465,\"enabled\":false}]",
                                           stackUserID: "alice")
        try await store.authorizeUserTailscaleRoutes(macDeviceID: "keyed-mac", instanceTag: "default",
                                                     stackUserID: "alice", teamID: nil, routes: [tailscale])
        // A pre-Iroh pairing: no key to verify.
        try await store.upsert(macDeviceID: "legacy-mac", displayName: "Legacy", routes: [tailscale],
                               instanceTag: "default", markActive: false, stackUserID: "alice", now: now)
        try await store.authorizeUserTailscaleRoutes(macDeviceID: "legacy-mac", instanceTag: "default",
                                                     stackUserID: "alice", teamID: nil, routes: [tailscale])
        // The setters omit `teamID` so they resolve to the store's own methods,
        // not the protocol's no-op compatibility defaults with the same labels.
        for mac in ["keyed-mac", "legacy-mac"] {
            try await store.setConnectionMethod(macDeviceID: mac, instanceTag: "default", rawValue: "tailscale",
                                                stackUserID: "alice")
        }
        try Self.setUserVersion(12, at: url)

        let reopened = try MobilePairedMacStore(databaseURL: url)
        let macs = try await reopened.loadAll(stackUserID: "alice", teamID: nil)
        let keyed = try #require(macs.first { $0.macDeviceID == "keyed-mac" })
        let legacy = try #require(macs.first { $0.macDeviceID == "legacy-mac" })

        #expect(keyed.connectionMethodRawValue == "direct")
        // The grants became Direct addresses; leaving them could resurrect a
        // removed address through the Iroh compatibility path.
        #expect(keyed.legacyTailscaleRoutes == nil)
        // The granted endpoint matched a disabled entry: migration re-enables
        // it (a converted pairing must not land with nothing dialable).
        #expect(keyed.directAddresses == [
            MobilePairedMacDirectAddress(address: "192.168.1.10", port: 58465),
            MobilePairedMacDirectAddress(address: "100.64.0.9", port: 58465, enabled: true),
        ])
        #expect(legacy.connectionMethodRawValue == nil)
        // The grant stays, so the Iroh method's legacy compatibility still dials it.
        #expect(legacy.legacyTailscaleRoutes == [tailscale])
    }

    /// A replacement code drops the stale code-derived endpoint, keeps the
    /// user's own entries, and re-enables a matching disabled one.
    @Test func replacementReconcilesCodeDerivedAddresses() throws {
        let old = try! CmxAttachRoute(
            id: "t1", kind: .tailscale, endpoint: .hostPort(host: "100.64.0.9", port: 58466))
        let replacement = try! CmxAttachRoute(
            id: "t2", kind: .tailscale, endpoint: .hostPort(host: "100.64.0.20", port: 58466))
        let start = [MobilePairedMacDirectAddress(address: "192.168.1.10", port: 58466)]
            .appendingTailscaleAddresses(from: [old])
        #expect(start.map(\.address) == ["192.168.1.10", "100.64.0.9"])

        let replaced = start.appendingTailscaleAddresses(from: [replacement])
        #expect(replaced == [
            MobilePairedMacDirectAddress(address: "192.168.1.10", port: 58466),
            MobilePairedMacDirectAddress(
                address: "100.64.0.20", port: 58466, label: "Tailscale",
                origin: MobilePairedMacDirectAddress.pairingCodeOrigin),
        ])
        // A renamed derived entry still reconciles (origin, not label).
        var renamed = start
        renamed[1].label = "Office"
        #expect(renamed.appendingTailscaleAddresses(from: [replacement]).map(\.address)
            == ["192.168.1.10", "100.64.0.20"])
        // A hand-added entry labeled "Tailscale" is never touched.
        let handAdded = [MobilePairedMacDirectAddress(address: "100.64.0.9", port: 58466, label: "Tailscale")]
        #expect(handAdded.appendingTailscaleAddresses(from: [replacement]).map(\.address)
            == ["100.64.0.9", "100.64.0.20"])
    }

    private static func setUserVersion(_ version: Int32, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA user_version = \(version);", nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

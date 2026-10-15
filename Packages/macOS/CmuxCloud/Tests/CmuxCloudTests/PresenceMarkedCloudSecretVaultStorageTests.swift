@testable import CmuxCloud
import Foundation
import Testing

/// The marker that lets a launch skip the Keychain when no vault exists.
@Suite struct PresenceMarkedCloudSecretVaultStorageTests {
    func makeMarkerURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-secrets-marker-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("cloud-secrets.present")
    }

    @Test
    func theMarkerFollowsTheVault() async throws {
        let markerURL = makeMarkerURL()
        defer { try? FileManager.default.removeItem(at: markerURL.deletingLastPathComponent()) }
        let base = InMemoryCloudSecretVaultStorage()
        let storage = PresenceMarkedCloudSecretVaultStorage(base: base, markerURL: markerURL)
        #expect(!storage.markerExists)

        let vault = CloudSecretVault(storage: storage)
        try await vault.set([CloudSecretInput(name: "A_KEY", value: "a-value")], scope: .all, source: .manual)
        #expect(storage.markerExists)
        // The marker carries nothing of the vault.
        #expect(try Data(contentsOf: markerURL).isEmpty)

        try storage.delete()
        #expect(!storage.markerExists)
        #expect(try base.load() == nil)
    }

    @Test
    func aReadReconcilesAMissingOrStaleMarker() throws {
        let markerURL = makeMarkerURL()
        defer { try? FileManager.default.removeItem(at: markerURL.deletingLastPathComponent()) }
        // A vault saved before markers existed gains one when it is read.
        let existing = PresenceMarkedCloudSecretVaultStorage(base: InMemoryCloudSecretVaultStorage(data: Data("{}".utf8)), markerURL: markerURL)
        #expect(!existing.markerExists)
        _ = try existing.load()
        #expect(existing.markerExists)
        // A marker whose vault is gone is removed by the read that finds nothing.
        let gone = PresenceMarkedCloudSecretVaultStorage(base: InMemoryCloudSecretVaultStorage(), markerURL: markerURL)
        #expect(gone.markerExists)
        #expect(try gone.load() == nil)
        #expect(!gone.markerExists)
    }
}

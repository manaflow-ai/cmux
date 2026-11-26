import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite
struct MobilePairedMacPersistenceFailureTests {
    @Test
    func failedDatabaseWriteRejectsConnectionPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let inner = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let defaultsSuite = "paired-mac-persistence-failure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        let shell = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: GatedUpsertStore(inner: inner, failUpsert: true),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            pairingHintDefaults: defaults
        )
        let route = try CmxAttachRoute(
            id: "iroh-test",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "a", count: 64)
                ),
                pathHints: []
            ),
            priority: 0
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-1",
            terminalID: "terminal-1",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date(timeIntervalSince1970: 4_102_444_800)
        )

        #expect(!(await shell.persistPairedMacFromTicket(ticket)))
        #expect(!shell.hasKnownPairedMac)
        #expect(try await inner.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        ).isEmpty)
    }
}

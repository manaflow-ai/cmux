import Foundation
import Testing
import CmuxMobilePairedMac
@testable import CmuxMobileShell

@Suite(.serialized)
struct PairedMacBackupMigrationTests {
    @Test func emptyV3CollectionAdoptsOneExplicitLegacyCollection() async throws {
        let defaultsSuite = "paired-mac-migration-\(UUID().uuidString)"
        let migrationDefaults = try #require(
            UserDefaults(suiteName: defaultsSuite)
        )
        let record = PairedMacBackupRecord(
            macDeviceID: "legacy-mac",
            displayName: "Legacy Mac",
            routes: [],
            createdAt: 1_000,
            lastSeenAt: 2_000,
            isActive: true
        )
        let legacyResponse = try JSONEncoder().encode(
            TestBackupList(records: [record], deletedMacDeviceIDs: [])
        )
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: Data(#"{"records":[],"deletedMacDeviceIDs":[]}"#.utf8),
            legacyScope: nil,
            legacyResponse: legacyResponse,
            primaryResponseAfterUpload: legacyResponse
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairedMacBackupMigrationURLProtocol.self]
        let client = PairedMacBackupClient(
            serviceBaseURL: "https://presence.example",
            tokenSource: PresenceTokenSource(
                accessToken: { "access-token" },
                currentUserID: { "user-1" }
            ),
            clientScopeProvider: { "ios:v3:Y29tLmNtdXguYXBw" },
            legacyClientScopeProvider: { nil },
            session: URLSession(configuration: configuration),
            migrationDefaults: migrationDefaults
        )

        let snapshot = try #require(
            await client.fetchSnapshot(teamID: nil, expectedUserID: "user-1")
        )

        #expect(snapshot.records == [record])
        let requests = PairedMacBackupMigrationURLProtocol.capturedRequests()
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "POST", "GET"])
        #expect(requests.map {
            $0.value(forHTTPHeaderField: "X-Cmux-Client-Scope")
        } == [
            "ios:v3:Y29tLmNtdXguYXBw",
            nil,
            "ios:v3:Y29tLmNtdXguYXBw",
            "ios:v3:Y29tLmNtdXguYXBw",
        ])
    }

    @Test func partiallyPopulatedV3CollectionReconcilesMissingLegacyRecords() async throws {
        let defaultsSuite = "paired-mac-migration-\(UUID().uuidString)"
        let migrationDefaults = try #require(
            UserDefaults(suiteName: defaultsSuite)
        )
        let current = PairedMacBackupRecord(
            macDeviceID: "current-mac",
            displayName: "Current Mac",
            routes: [],
            createdAt: 1_000,
            lastSeenAt: 2_000,
            isActive: true
        )
        let legacy = PairedMacBackupRecord(
            macDeviceID: "legacy-mac",
            displayName: "Legacy Mac",
            routes: [],
            createdAt: 1_000,
            lastSeenAt: 2_000,
            isActive: false
        )
        let combinedResponse = try JSONEncoder().encode(
            TestBackupList(
                records: [current, legacy],
                deletedMacDeviceIDs: []
            )
        )
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: try JSONEncoder().encode(
                TestBackupList(records: [current], deletedMacDeviceIDs: [])
            ),
            legacyScope: nil,
            legacyResponse: try JSONEncoder().encode(
                TestBackupList(records: [legacy], deletedMacDeviceIDs: [])
            ),
            primaryResponseAfterUpload: combinedResponse
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairedMacBackupMigrationURLProtocol.self]
        let client = PairedMacBackupClient(
            serviceBaseURL: "https://presence.example",
            tokenSource: PresenceTokenSource(
                accessToken: { "access-token" },
                currentUserID: { "user-1" }
            ),
            clientScopeProvider: { "ios:v3:Y29tLmNtdXguYXBw" },
            legacyClientScopeProvider: { nil },
            session: URLSession(configuration: configuration),
            migrationDefaults: migrationDefaults
        )

        let snapshot = try #require(
            await client.fetchSnapshot(teamID: nil, expectedUserID: "user-1")
        )

        #expect(snapshot.records == [current, legacy])
        let requests = PairedMacBackupMigrationURLProtocol.capturedRequests()
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "POST", "GET"])
    }

    @Test func currentTombstonePreventsLegacyRecordResurrection() async throws {
        let defaultsSuite = "paired-mac-migration-\(UUID().uuidString)"
        let migrationDefaults = try #require(
            UserDefaults(suiteName: defaultsSuite)
        )
        let legacy = PairedMacBackupRecord(
            macDeviceID: "forgotten-mac",
            displayName: "Forgotten Mac",
            routes: [],
            createdAt: 1_000,
            lastSeenAt: 2_000,
            isActive: false,
            instanceTag: "nightly"
        )
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: legacy.macDeviceID,
            instanceTag: legacy.instanceTag
        )
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: try JSONEncoder().encode(
                TestBackupList(
                    records: [],
                    deletedMacDeviceIDs: [pairingID]
                )
            ),
            legacyScope: nil,
            legacyResponse: try JSONEncoder().encode(
                TestBackupList(records: [legacy], deletedMacDeviceIDs: [])
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairedMacBackupMigrationURLProtocol.self]
        let client = PairedMacBackupClient(
            serviceBaseURL: "https://presence.example",
            tokenSource: PresenceTokenSource(
                accessToken: { "access-token" },
                currentUserID: { "user-1" }
            ),
            clientScopeProvider: { "ios:v3:Y29tLmNtdXguYXBw" },
            legacyClientScopeProvider: { nil },
            session: URLSession(configuration: configuration),
            migrationDefaults: migrationDefaults
        )

        let snapshot = try #require(
            await client.fetchSnapshot(teamID: nil, expectedUserID: "user-1")
        )

        #expect(snapshot.records.isEmpty)
        #expect(snapshot.deletedMacDeviceIDs == [pairingID])
        #expect(
            PairedMacBackupMigrationURLProtocol.capturedRequests()
                .map(\.httpMethod) == ["GET", "GET"]
        )
    }
}

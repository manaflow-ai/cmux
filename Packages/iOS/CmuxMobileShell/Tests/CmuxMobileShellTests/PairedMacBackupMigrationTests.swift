import Foundation
import Testing
import CmuxMobilePairedMac
@testable import CmuxMobileShell

@Suite(.serialized)
struct PairedMacBackupMigrationTests {
    @Test func migrationPinsServerVerifiedTeamAfterDefaultTeamRead() async throws {
        let defaultsSuite = "paired-mac-migration-\(UUID().uuidString)"
        let migrationDefaults = try #require(
            UserDefaults(suiteName: defaultsSuite)
        )
        let legacy = PairedMacBackupRecord(
            macDeviceID: "legacy-mac",
            displayName: "Legacy Mac",
            routes: [],
            createdAt: 1_000,
            lastSeenAt: 2_000,
            isActive: true
        )
        let primaryResponse = try JSONEncoder().encode(
            TestBackupList(
                records: [],
                deletedMacDeviceIDs: [],
                teamId: "team-from-server"
            )
        )
        let migratedResponse = try JSONEncoder().encode(
            TestBackupList(
                records: [legacy],
                deletedMacDeviceIDs: [],
                revision: 1,
                teamId: "team-from-server"
            )
        )
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: primaryResponse,
            legacyScope: nil,
            legacyResponse: try JSONEncoder().encode(
                TestBackupList(
                    records: [legacy],
                    deletedMacDeviceIDs: [],
                    teamId: "team-from-server"
                )
            ),
            primaryResponseAfterUpload: migratedResponse
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

        #expect(snapshot.records == [legacy])
        #expect(
            PairedMacBackupMigrationURLProtocol.capturedRequests().map {
                $0.value(forHTTPHeaderField: "X-Cmux-Team-Id")
            } == [nil, "team-from-server", "team-from-server", "team-from-server"]
        )
    }

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
            primaryResponse: Data(
                #"{"records":[],"deletedMacDeviceIDs":[],"revision":0,"teamId":"team-1"}"#.utf8
            ),
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

    @Test func currentGlobalTombstonePreventsTaggedLegacyRecordResurrection() async throws {
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
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: try JSONEncoder().encode(
                TestBackupList(records: [], deletedMacDeviceIDs: ["forgotten-mac"])
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
        #expect(snapshot.deletedMacDeviceIDs == ["forgotten-mac"])
        #expect(
            PairedMacBackupMigrationURLProtocol.capturedRequests()
                .map(\.httpMethod) == ["GET", "GET"]
        )
    }

    @Test func currentTaggedRecordPreventsLegacyGlobalTombstoneDeletingIt() async throws {
        let defaultsSuite = "paired-mac-migration-\(UUID().uuidString)"
        let migrationDefaults = try #require(
            UserDefaults(suiteName: defaultsSuite)
        )
        let current = PairedMacBackupRecord(
            macDeviceID: "repaired-mac",
            displayName: "Repaired Mac",
            routes: [],
            createdAt: 3_000,
            lastSeenAt: 4_000,
            isActive: true,
            instanceTag: "nightly"
        )
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: try JSONEncoder().encode(
                TestBackupList(records: [current], deletedMacDeviceIDs: [])
            ),
            legacyScope: nil,
            legacyResponse: try JSONEncoder().encode(
                TestBackupList(records: [], deletedMacDeviceIDs: ["repaired-mac"])
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

        #expect(snapshot.records == [current])
        #expect(snapshot.deletedMacDeviceIDs.isEmpty)
        #expect(
            PairedMacBackupMigrationURLProtocol.capturedRequests()
                .map(\.httpMethod) == ["GET", "GET"]
        )
    }

    @Test func siblingTaggedLegacyTombstoneIsMigrated() async throws {
        let defaultsSuite = "paired-mac-migration-\(UUID().uuidString)"
        let migrationDefaults = try #require(
            UserDefaults(suiteName: defaultsSuite)
        )
        let current = PairedMacBackupRecord(
            macDeviceID: "repaired-mac",
            displayName: "Beta Mac",
            routes: [],
            createdAt: 3_000,
            lastSeenAt: 4_000,
            isActive: true,
            instanceTag: "beta"
        )
        let legacyTombstone = "repaired-mac:nightly"
        let currentResponse = try JSONEncoder().encode(
            TestBackupList(records: [current], deletedMacDeviceIDs: [])
        )
        let migratedResponse = try JSONEncoder().encode(
            TestBackupList(
                records: [current],
                deletedMacDeviceIDs: [legacyTombstone]
            )
        )
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: currentResponse,
            legacyScope: nil,
            legacyResponse: try JSONEncoder().encode(
                TestBackupList(records: [], deletedMacDeviceIDs: [legacyTombstone])
            ),
            primaryResponseAfterUpload: migratedResponse
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

        #expect(snapshot.records == [current])
        #expect(snapshot.deletedMacDeviceIDs == [legacyTombstone])
        #expect(
            PairedMacBackupMigrationURLProtocol.capturedRequests()
                .map(\.httpMethod) == ["GET", "GET", "POST", "GET"]
        )
    }

    @Test func legacyTombstoneMigratesAndRejectsLaterStaleUpsert() async throws {
        let defaultsSuite = "paired-mac-migration-\(UUID().uuidString)"
        let migrationDefaults = try #require(
            UserDefaults(suiteName: defaultsSuite)
        )
        let stale = PairedMacBackupRecord(
            macDeviceID: "forgotten-mac",
            displayName: "Forgotten Mac",
            routes: [],
            createdAt: 1_000,
            lastSeenAt: 2_000,
            isActive: false,
            instanceTag: "nightly"
        )
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: stale.macDeviceID,
            instanceTag: stale.instanceTag
        )
        let empty = try JSONEncoder().encode(
            TestBackupList(records: [], deletedMacDeviceIDs: [])
        )
        let tombstoned = try JSONEncoder().encode(
            TestBackupList(
                records: [],
                deletedMacDeviceIDs: [pairingID]
            )
        )
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: empty,
            legacyScope: nil,
            legacyResponse: tombstoned,
            primaryResponseAfterUpload: tombstoned
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

        let migrated = try #require(
            await client.fetchSnapshot(teamID: nil, expectedUserID: "user-1")
        )
        #expect(migrated.records.isEmpty)
        #expect(migrated.deletedMacDeviceIDs == [pairingID])
        let migrationRequests =
            PairedMacBackupMigrationURLProtocol.capturedRequests()
        #expect(
            migrationRequests.map(\.httpMethod)
                == ["GET", "GET", "POST", "GET"]
        )
        let migrationBody = try #require(
            PairedMacBackupMigrationURLProtocol.capturedRequestBodies()
                .dropFirst(2)
                .first
        )
        let unwrappedMigrationBody = try #require(migrationBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: unwrappedMigrationBody)
                as? [String: Any]
        )
        let ops = try #require(object["ops"] as? [[String: Any]])
        #expect(object["expectedRevision"] as? Int == 0)
        #expect(ops.count == 1)
        #expect(ops[0]["macDeviceID"] as? String == stale.macDeviceID)
        #expect(ops[0]["instanceTag"] as? String == "nightly")
        #expect(ops[0]["deleted"] as? Bool == true)

        #expect(await client.upload(
            ops: [.upsert(stale)],
            teamID: nil,
            expectedUserID: "user-1"
        ))
        let afterStaleUpsert = try #require(
            await client.fetchSnapshot(teamID: nil, expectedUserID: "user-1")
        )
        #expect(afterStaleUpsert.records.isEmpty)
        #expect(afterStaleUpsert.deletedMacDeviceIDs == [pairingID])
    }

    @Test func currentV3RecordWinsConflictingLegacyTombstone() async throws {
        let defaultsSuite = "paired-mac-migration-\(UUID().uuidString)"
        let migrationDefaults = try #require(
            UserDefaults(suiteName: defaultsSuite)
        )
        let current = PairedMacBackupRecord(
            macDeviceID: "repaired-mac",
            displayName: "Re-paired Mac",
            routes: [],
            createdAt: 3_000,
            lastSeenAt: 4_000,
            isActive: true,
            instanceTag: "nightly"
        )
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: current.macDeviceID,
            instanceTag: current.instanceTag
        )
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: try JSONEncoder().encode(
                TestBackupList(records: [current], deletedMacDeviceIDs: [])
            ),
            legacyScope: nil,
            legacyResponse: try JSONEncoder().encode(
                TestBackupList(
                    records: [],
                    deletedMacDeviceIDs: [pairingID]
                )
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

        #expect(snapshot.records == [current])
        #expect(snapshot.deletedMacDeviceIDs.isEmpty)
        #expect(
            PairedMacBackupMigrationURLProtocol.capturedRequests()
                .map(\.httpMethod) == ["GET", "GET"]
        )
    }

    @Test func legacyFetchFailureRemainsRetryable() async throws {
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
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: try JSONEncoder().encode(
                TestBackupList(records: [current], deletedMacDeviceIDs: [])
            ),
            legacyScope: nil,
            legacyResponse: Data("invalid-json".utf8)
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

        let first = await client.fetchSnapshot(
            teamID: nil,
            expectedUserID: "user-1"
        )
        let second = await client.fetchSnapshot(
            teamID: nil,
            expectedUserID: "user-1"
        )

        #expect(first?.records == [current])
        #expect(second?.records == [current])
        #expect(first?.requiresMigrationRetry == true)
        #expect(second?.requiresMigrationRetry == true)
        #expect(
            PairedMacBackupMigrationURLProtocol.capturedRequests()
                .map(\.httpMethod) == ["GET", "GET", "GET", "GET"]
        )
    }

    @Test func revisionConflictReturnsCurrentSnapshotAndRemainsRetryable() async throws {
        let defaultsSuite = "paired-mac-migration-\(UUID().uuidString)"
        let migrationDefaults = try #require(
            UserDefaults(suiteName: defaultsSuite)
        )
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: "repaired-mac",
            instanceTag: "nightly"
        )
        let current = PairedMacBackupRecord(
            macDeviceID: "current-mac",
            displayName: "Current Mac",
            routes: [],
            createdAt: 1_000,
            lastSeenAt: 2_000,
            isActive: true
        )
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: try JSONEncoder().encode(
                TestBackupList(
                    records: [current],
                    deletedMacDeviceIDs: [],
                    revision: 7
                )
            ),
            legacyScope: nil,
            legacyResponse: try JSONEncoder().encode(
                TestBackupList(
                    records: [],
                    deletedMacDeviceIDs: [pairingID]
                )
            ),
            uploadStatusCode: 409
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            PairedMacBackupMigrationURLProtocol.self
        ]
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

        let snapshot = await client.fetchSnapshot(
            teamID: nil,
            expectedUserID: "user-1"
        )

        #expect(snapshot?.records == [current])
        #expect(snapshot?.requiresMigrationRetry == true)
        #expect(
            PairedMacBackupMigrationURLProtocol.capturedRequests()
                .map(\.httpMethod) == ["GET", "GET", "POST"]
        )
        let body = try #require(
            PairedMacBackupMigrationURLProtocol.capturedRequestBodies()
                .compactMap { $0 }
                .first
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["expectedRevision"] as? Int == 7)
    }

    @Test func legacyAdoptionUsesOneConditionalBatchPerFetch() async throws {
        let defaultsSuite = "paired-mac-migration-\(UUID().uuidString)"
        let migrationDefaults = try #require(
            UserDefaults(suiteName: defaultsSuite)
        )
        let tombstones = (0 ..< 201).map { "forgotten-\($0):nightly" }
        let empty = try JSONEncoder().encode(
            TestBackupList(records: [], deletedMacDeviceIDs: [])
        )
        let legacy = try JSONEncoder().encode(
            TestBackupList(
                records: [],
                deletedMacDeviceIDs: tombstones
            )
        )
        let migratedTombstones = Array(tombstones.prefix(200))
        let migrated = try JSONEncoder().encode(
            TestBackupList(
                records: [],
                deletedMacDeviceIDs: migratedTombstones,
                revision: 200
            )
        )
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: empty,
            legacyScope: nil,
            legacyResponse: legacy,
            primaryResponseAfterUpload: migrated
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            PairedMacBackupMigrationURLProtocol.self
        ]
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

        #expect(snapshot.deletedMacDeviceIDs == migratedTombstones)
        #expect(
            PairedMacBackupMigrationURLProtocol.capturedRequests()
                .map(\.httpMethod)
                == ["GET", "GET", "POST", "GET"]
        )
        let postBodies = PairedMacBackupMigrationURLProtocol
            .capturedRequestBodies()
            .compactMap { $0 }
        let opCounts = try postBodies.map { body in
            let object = try #require(
                JSONSerialization.jsonObject(with: body)
                    as? [String: Any]
            )
            return try #require(object["ops"] as? [[String: Any]]).count
        }
        #expect(opCounts == [200])
    }

    @Test func legacyMigrationCapsUploadsPerFetch() async throws {
        let defaultsSuite = "paired-mac-migration-\(UUID().uuidString)"
        let migrationDefaults = try #require(
            UserDefaults(suiteName: defaultsSuite)
        )
        let tombstones = (0 ..< 401).map { "forgotten-\($0)" }
        let empty = try JSONEncoder().encode(
            TestBackupList(records: [], deletedMacDeviceIDs: [])
        )
        let legacy = try JSONEncoder().encode(
            TestBackupList(records: [], deletedMacDeviceIDs: tombstones)
        )
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: empty,
            legacyScope: nil,
            legacyResponse: legacy,
            primaryResponseAfterUpload: empty
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            PairedMacBackupMigrationURLProtocol.self
        ]
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

        _ = await client.fetchSnapshot(teamID: nil, expectedUserID: "user-1")

        #expect(
            PairedMacBackupMigrationURLProtocol.capturedRequests()
                .map(\.httpMethod) == ["GET", "GET", "POST", "GET"]
        )
        let postBodies = PairedMacBackupMigrationURLProtocol
            .capturedRequestBodies()
            .compactMap { $0 }
        let opCounts = try postBodies.map { body in
            let object = try #require(
                JSONSerialization.jsonObject(with: body)
                    as? [String: Any]
            )
            return try #require(object["ops"] as? [[String: Any]]).count
        }
        #expect(opCounts == [200])
    }

    @Test func legacyUpdatesRemainReconciledAfterInitialMigration() async throws {
        let defaultsSuite = "paired-mac-migration-\(UUID().uuidString)"
        let migrationDefaults = try #require(
            UserDefaults(suiteName: defaultsSuite)
        )
        let clock = PairedMacMigrationClock()
        let first = PairedMacBackupRecord(
            macDeviceID: "first-legacy-mac",
            displayName: "First Legacy Mac",
            routes: [],
            createdAt: 1_000,
            lastSeenAt: 2_000,
            isActive: true
        )
        let second = PairedMacBackupRecord(
            macDeviceID: "second-legacy-mac",
            displayName: "Second Legacy Mac",
            routes: [],
            createdAt: 3_000,
            lastSeenAt: 4_000,
            isActive: true
        )
        let empty = try JSONEncoder().encode(
            TestBackupList(records: [], deletedMacDeviceIDs: [])
        )
        let firstResponse = try JSONEncoder().encode(
            TestBackupList(records: [first], deletedMacDeviceIDs: [])
        )
        let combinedResponse = try JSONEncoder().encode(
            TestBackupList(records: [first, second], deletedMacDeviceIDs: [])
        )
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: empty,
            legacyScope: nil,
            legacyResponse: firstResponse,
            primaryResponseAfterUpload: firstResponse
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
            migrationDefaults: migrationDefaults,
            migrationClock: { clock.now }
        )

        _ = try #require(
            await client.fetchSnapshot(teamID: nil, expectedUserID: "user-1")
        )

        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: firstResponse,
            legacyScope: nil,
            legacyResponse: try JSONEncoder().encode(
                TestBackupList(records: [second], deletedMacDeviceIDs: [])
            ),
            primaryResponseAfterUpload: combinedResponse
        )
        let duringCooldown = try #require(
            await client.fetchSnapshot(teamID: nil, expectedUserID: "user-1")
        )
        #expect(duringCooldown.records == [first])
        #expect(
            PairedMacBackupMigrationURLProtocol.capturedRequests()
                .map(\.httpMethod) == ["GET"]
        )

        clock.advance(by: 61)
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: firstResponse,
            legacyScope: nil,
            legacyResponse: try JSONEncoder().encode(
                TestBackupList(records: [second], deletedMacDeviceIDs: [])
            ),
            primaryResponseAfterUpload: combinedResponse
        )
        let snapshot = try #require(
            await client.fetchSnapshot(teamID: nil, expectedUserID: "user-1")
        )

        #expect(snapshot.records == [first, second])
        #expect(
            PairedMacBackupMigrationURLProtocol.capturedRequests()
                .map(\.httpMethod) == ["GET", "GET", "POST", "GET"]
        )
    }

    @Test func migrationCompletionDoesNotCrossAccountsWithoutExpectedUserID() async throws {
        let defaultsSuite = "paired-mac-migration-\(UUID().uuidString)"
        let migrationDefaults = try #require(
            UserDefaults(suiteName: defaultsSuite)
        )
        let user = MigrationUserProbe(value: "user-a")
        let empty = Data(
            #"{"records":[],"deletedMacDeviceIDs":[],"revision":0,"teamId":"team-1"}"#.utf8
        )
        PairedMacBackupMigrationURLProtocol.reset(
            primaryScope: "ios:v3:Y29tLmNtdXguYXBw",
            primaryResponse: empty,
            legacyScope: nil,
            legacyResponse: empty
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairedMacBackupMigrationURLProtocol.self]
        let client = PairedMacBackupClient(
            serviceBaseURL: "https://presence.example",
            tokenSource: PresenceTokenSource(
                accessToken: { "access-token" },
                currentUserID: { await user.value() }
            ),
            clientScopeProvider: { "ios:v3:Y29tLmNtdXguYXBw" },
            legacyClientScopeProvider: { nil },
            session: URLSession(configuration: configuration),
            migrationDefaults: migrationDefaults
        )

        _ = await client.fetchSnapshot(teamID: nil)
        await user.setValue("user-b")
        _ = await client.fetchSnapshot(teamID: nil)

        #expect(
            PairedMacBackupMigrationURLProtocol.capturedRequests()
                .map(\.httpMethod) == ["GET", "GET", "GET", "GET"]
        )
    }
}

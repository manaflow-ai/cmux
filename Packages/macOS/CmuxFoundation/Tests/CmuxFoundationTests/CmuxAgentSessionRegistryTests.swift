import Foundation
import SQLite3
import Testing
@testable import CmuxFoundation

@Suite("Agent session registry", .serialized)
struct CmuxAgentSessionRegistryTests {
    @Test("legacy rewrites cannot erase current session metadata")
    func legacyRewriteDoesNotEraseCurrentMetadata() throws {
        let fixture = try Fixture()
        let current = try fixture.record(
            sessionID: "codex-current",
            updatedAt: 20,
            generation: 1,
            extra: ["cmuxRuntime": ["id": "tagged-runtime"], "runs": [["runId": "run-1"]]]
        )
        try fixture.registry.apply(provider: "codex", records: [current])

        let legacy = try fixture.legacyStore(
            sessions: ["codex-current": fixture.object(sessionID: "codex-current", updatedAt: 21)]
        )
        let stamp = CmuxAgentSessionRegistry.LegacyStamp(
            path: fixture.directory.appendingPathComponent("codex-hook-sessions.json").path,
            size: Int64(legacy.count),
            modifiedAt: 21
        )
        try fixture.registry.importLegacyStoreJSON(provider: "codex", stamp: stamp, json: legacy)

        let stored = try #require(fixture.registry.snapshot(provider: "codex").records.first)
        let object = try #require(JSONSerialization.jsonObject(with: stored.json) as? [String: Any])
        let runtime = try #require(object["cmuxRuntime"] as? [String: Any])
        #expect(runtime["id"] as? String == "tagged-runtime")
        #expect(stored.writerGeneration == 1)
    }

    @Test("older registry generations cannot replace future rows")
    func writerGenerationIsMonotonic() throws {
        let fixture = try Fixture()
        try fixture.registry.apply(provider: "claude", records: [
            try fixture.record(
                sessionID: "future",
                updatedAt: 30,
                generation: 2,
                extra: ["futureState": "watching"]
            ),
        ])
        try fixture.registry.apply(provider: "claude", records: [
            try fixture.record(sessionID: "future", updatedAt: 40, generation: 1),
        ])

        let stored = try #require(fixture.registry.snapshot(provider: "claude").records.first)
        let object = try #require(JSONSerialization.jsonObject(with: stored.json) as? [String: Any])
        #expect(object["futureState"] as? String == "watching")
        #expect(stored.writerGeneration == 2)
    }

    @Test("partial legacy snapshots cannot erase the last complete import")
    func partialLegacySnapshotDoesNotReplaceCompleteImport() throws {
        let fixture = try Fixture()
        let original = try fixture.legacyStore(
            sessions: ["durable": fixture.object(sessionID: "durable", updatedAt: 10)]
        )
        try fixture.registry.importLegacyStoreJSON(
            provider: "codex",
            stamp: CmuxAgentSessionRegistry.LegacyStamp(path: "legacy", size: Int64(original.count), modifiedAt: 10),
            json: original
        )
        let partial = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                "durable": fixture.object(sessionID: "durable", updatedAt: 11),
                "partial": "incomplete-record",
            ],
        ])

        #expect(throws: (any Error).self) {
            try fixture.registry.importLegacyStoreJSON(
                provider: "codex",
                stamp: CmuxAgentSessionRegistry.LegacyStamp(path: "legacy", size: Int64(partial.count), modifiedAt: 11),
                json: partial
            )
        }
        let snapshot = try fixture.registry.snapshot(provider: "codex")
        #expect(snapshot.records.map(\.sessionID) == ["durable"])
        #expect(snapshot.records.first?.updatedAt == 10)
    }

    @Test("duplicate legacy source requests are idempotent")
    func duplicateLegacySourcesAreIdempotent() throws {
        let fixture = try Fixture()
        let legacyURL = fixture.directory.appendingPathComponent("codex-hook-sessions.json")
        try fixture.legacyStore(
            sessions: ["one": fixture.object(sessionID: "one", updatedAt: 1)]
        ).write(to: legacyURL, options: .atomic)
        let source = CmuxAgentSessionRegistry.LegacySource(provider: "codex", url: legacyURL)

        let snapshots = try fixture.registry.snapshotsImportingLegacy(sources: [source, source])

        #expect(snapshots["codex"]?.records.map(\.sessionID) == ["one"])
    }

    @Test("restore preflight isolates a malformed legacy provider")
    func restorePreflightIsolatesMalformedProvider() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let codexURL = fixture.directory.appendingPathComponent("codex-hook-sessions.json")
        let claudeURL = fixture.directory.appendingPathComponent("claude-hook-sessions.json")
        try fixture.legacyStore(
            sessions: ["codex-session": fixture.object(sessionID: "codex-session", updatedAt: 1)]
        ).write(to: codexURL, options: .atomic)
        try Data("{broken".utf8).write(to: claudeURL, options: .atomic)

        let result = try fixture.registry.refreshLegacySources([
            .init(provider: "claude", url: claudeURL),
            .init(provider: "codex", url: codexURL),
        ])

        #expect(result.refreshedProviders == ["codex"])
        #expect(result.failedProviders == ["claude"])
        #expect(try fixture.registry.snapshot(provider: "codex").records.map(\.sessionID) == ["codex-session"])
        #expect(try fixture.registry.snapshot(provider: "claude").records.isEmpty)
    }

    @Test("restore preflight imports ten thousand legacy rows within a bounded interval")
    func restorePreflightPerformance() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let legacyURL = fixture.directory.appendingPathComponent("codex-hook-sessions.json")
        let sessions = Dictionary(uniqueKeysWithValues: (0..<10_000).map { index in
            let sessionID = "session-\(index)"
            return (sessionID, fixture.object(sessionID: sessionID, updatedAt: Double(index)))
        })
        try fixture.legacyStore(sessions: sessions).write(to: legacyURL, options: .atomic)

        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            let result = try fixture.registry.refreshLegacySources([
                .init(provider: "codex", url: legacyURL),
            ])
            #expect(result.refreshedProviders == ["codex"])
            #expect(result.failedProviders.isEmpty)
        }

        print("restore preflight 10000-row elapsed: \(elapsed)")
        #expect(elapsed < .seconds(5))
        #expect(try fixture.registry.snapshot(provider: "codex").records.count == 10_000)

        let unchangedElapsed = try clock.measure {
            let result = try fixture.registry.refreshLegacySources([
                .init(provider: "codex", url: legacyURL),
            ])
            #expect(result.refreshedProviders.isEmpty)
            #expect(result.failedProviders.isEmpty)
        }
        print("restore preflight unchanged 10000-row elapsed: \(unchangedElapsed)")
        #expect(unchangedElapsed < .seconds(1))
    }

    @Test("restore preflight spends one busy timeout waiting for a writer")
    func restorePreflightContentionIsBounded() throws {
        let fixture = try Fixture(busyTimeoutMilliseconds: 5)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.registry.snapshot(provider: "codex")
        let legacyURL = fixture.directory.appendingPathComponent("codex-hook-sessions.json")
        try fixture.legacyStore(
            sessions: ["blocked": fixture.object(sessionID: "blocked", updatedAt: 1)]
        ).write(to: legacyURL, options: .atomic)
        var database: OpaquePointer?
        #expect(sqlite3_open(fixture.registry.url.path, &database) == SQLITE_OK)
        let writer = try #require(database)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(throws: (any Error).self) {
                try fixture.registry.refreshLegacySources([
                    .init(provider: "codex", url: legacyURL),
                ])
            }
        }

        #expect(elapsed < .seconds(1))
    }

    @Test("missing legacy sources fail restore preflight closed")
    func restorePreflightRejectsMissingLegacySource() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try fixture.registry.refreshLegacySources([
            .init(
                provider: "codex",
                url: fixture.directory.appendingPathComponent("missing-codex-hook-sessions.json")
            ),
        ])

        #expect(result.refreshedProviders.isEmpty)
        #expect(result.failedProviders == ["codex"])
    }

    @Test("missing compatibility JSON does not discard a canonical registry row")
    func canonicalRegistryRestoresWithoutLegacySource() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let missingURL = fixture.directory.appendingPathComponent("missing-codex-hook-sessions.json")
        try fixture.registry.apply(provider: "codex", records: [
            try fixture.record(
                sessionID: "canonical",
                updatedAt: 1,
                generation: 1,
                extra: ["sessionState": "hibernated"]
            ),
        ])

        let preflight = try fixture.registry.refreshLegacySources([
            .init(provider: "codex", url: missingURL),
        ])
        #expect(preflight.refreshedProviders.isEmpty)
        #expect(preflight.failedProviders.isEmpty)
        let result = try fixture.registry.withLegacySourceRebindBatch(
            provider: "codex",
            legacyURL: missingURL
        ) { batch in
            try batch.patchRecordRebindingActiveSlots(
                provider: "codex",
                sessionID: "canonical",
                updatedAt: 2,
                previousSlots: [],
                activeSlots: [],
                shouldMutate: { $0["sessionState"] as? String == "hibernated" }
            ) { object in
                object["workspaceId"] = "restored-workspace"
                object["updatedAt"] = 2.0
            }
        }

        #expect(result == .patched)
        let record = try #require(fixture.registry.snapshot(provider: "codex").records.first)
        let object = try #require(JSONSerialization.jsonObject(with: record.json) as? [String: Any])
        #expect(object["workspaceId"] as? String == "restored-workspace")
    }

    @Test("missing compatibility lookup stays bounded with ten thousand canonical rows")
    func missingLegacyCanonicalLookupPerformance() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let records = try (0..<10_000).map { index in
            try fixture.record(
                sessionID: "canonical-\(index)",
                updatedAt: Double(index),
                generation: 1
            )
        }
        try fixture.registry.apply(provider: "codex", records: records)
        let missingURL = fixture.directory.appendingPathComponent("missing-codex-hook-sessions.json")

        let elapsed = try ContinuousClock().measure {
            let result = try fixture.registry.refreshLegacySources([
                .init(provider: "codex", url: missingURL),
            ])
            #expect(result.failedProviders.isEmpty)
        }

        #expect(elapsed < .seconds(1))
    }

    @Test("lifecycle patches preserve unknown future keys")
    func patchPreservesUnknownKeys() throws {
        let fixture = try Fixture()
        try fixture.registry.apply(provider: "opencode", records: [
            try fixture.record(
                sessionID: "patched",
                updatedAt: 10,
                generation: 2,
                extra: ["futureWorkload": ["monitor": true]]
            ),
        ])

        let patched = try fixture.registry.patchRecord(
            provider: "opencode",
            sessionID: "patched",
            updatedAt: 50
        ) { object in
            object["sessionState"] = "hibernated"
            object["updatedAt"] = 50
        }

        #expect(patched)
        let stored = try #require(fixture.registry.snapshot(provider: "opencode").records.first)
        let object = try #require(JSONSerialization.jsonObject(with: stored.json) as? [String: Any])
        #expect((object["futureWorkload"] as? [String: Any])?["monitor"] as? Bool == true)
        #expect(object["sessionState"] as? String == "hibernated")
        #expect(stored.writerGeneration == 2)
    }

    @Test("lifecycle patches promote imported legacy rows")
    func patchPromotesLegacyWriterGeneration() throws {
        let fixture = try Fixture()
        try fixture.registry.apply(provider: "codex", records: [
            try fixture.record(sessionID: "legacy", updatedAt: 10, generation: 0),
        ])

        let patched = try fixture.registry.patchRecord(
            provider: "codex",
            sessionID: "legacy",
            updatedAt: 20
        ) { object in
            object["sessionState"] = "hibernated"
            object["updatedAt"] = 20
        }

        #expect(patched)
        let stored = try #require(fixture.registry.snapshot(provider: "codex").records.first)
        #expect(stored.writerGeneration == CmuxAgentSessionRegistry.currentWriterGeneration)
    }

    @Test("record and active panel bindings rebind atomically")
    func recordAndActivePanelBindingsRebindAtomically() throws {
        let fixture = try Fixture()
        let oldWorkspace = "11111111-1111-1111-1111-111111111111"
        let oldSurface = "22222222-2222-2222-2222-222222222222"
        let newWorkspace = "33333333-3333-3333-3333-333333333333"
        let newSurface = "44444444-4444-4444-4444-444444444444"
        try fixture.registry.apply(
            provider: "codex",
            records: [try fixture.record(
                sessionID: "restored",
                updatedAt: 10,
                generation: 2,
                extra: ["futureRecordKey": "preserved"]
            )],
            activeSlots: [
                try fixture.slot(
                    provider: "codex",
                    scope: .workspace,
                    scopeID: oldWorkspace,
                    sessionID: "restored",
                    updatedAt: 10,
                    generation: 2,
                    extra: ["futureSlotKey": "preserved"]
                ),
                try fixture.slot(
                    provider: "codex",
                    scope: .surface,
                    scopeID: oldSurface,
                    sessionID: "restored",
                    updatedAt: 10,
                    generation: 2
                ),
            ]
        )

        let patched = try fixture.registry.patchRecordRebindingActiveSlots(
            provider: "codex",
            sessionID: "restored",
            updatedAt: 20,
            previousSlots: [
                .init(scope: .workspace, scopeID: oldWorkspace),
                .init(scope: .surface, scopeID: oldSurface),
            ],
            activeSlots: [
                .init(scope: .workspace, scopeID: newWorkspace),
                .init(scope: .surface, scopeID: newSurface),
            ],
            shouldMutate: {
                $0["workspaceId"] as? String == oldWorkspace
                    && $0["surfaceId"] as? String == oldSurface
            }
        ) { object in
            object["workspaceId"] = newWorkspace
            object["surfaceId"] = newSurface
            object["updatedAt"] = 20
            object["sessionState"] = "hibernated"
        }

        #expect(patched == .patched)
        let snapshot = try fixture.registry.snapshot(provider: "codex")
        let record = try #require(snapshot.records.first)
        let object = try #require(JSONSerialization.jsonObject(with: record.json) as? [String: Any])
        #expect(object["workspaceId"] as? String == newWorkspace)
        #expect(object["surfaceId"] as? String == newSurface)
        #expect(object["futureRecordKey"] as? String == "preserved")
        #expect(record.writerGeneration == 2)
        #expect(Set(snapshot.activeSlots.map(\.scopeID)) == [newWorkspace, newSurface])
        for slot in snapshot.activeSlots {
            let slotObject = try #require(JSONSerialization.jsonObject(with: slot.json) as? [String: Any])
            #expect(slot.sessionID == "restored")
            #expect(slot.writerGeneration == 2)
            #expect(slotObject["futureSlotKey"] as? String == "preserved")
        }
    }

    @Test("active slot collisions reject the complete rebind")
    func activeSlotCollisionRejectsCompleteRebind() throws {
        let fixture = try Fixture()
        let oldWorkspace = "11111111-1111-1111-1111-111111111111"
        let oldSurface = "22222222-2222-2222-2222-222222222222"
        let occupiedWorkspace = "33333333-3333-3333-3333-333333333333"
        let newSurface = "44444444-4444-4444-4444-444444444444"
        try fixture.registry.apply(
            provider: "codex",
            records: [
                try fixture.record(sessionID: "restored", updatedAt: 10, generation: 1),
                try fixture.record(sessionID: "occupant", updatedAt: 11, generation: 1),
            ],
            activeSlots: [
                try fixture.slot(
                    provider: "codex",
                    scope: .workspace,
                    scopeID: oldWorkspace,
                    sessionID: "restored",
                    updatedAt: 10
                ),
                try fixture.slot(
                    provider: "codex",
                    scope: .surface,
                    scopeID: oldSurface,
                    sessionID: "restored",
                    updatedAt: 10
                ),
                try fixture.slot(
                    provider: "codex",
                    scope: .workspace,
                    scopeID: occupiedWorkspace,
                    sessionID: "occupant",
                    updatedAt: 11
                ),
            ]
        )

        let patched = try fixture.registry.patchRecordRebindingActiveSlots(
            provider: "codex",
            sessionID: "restored",
            updatedAt: 20,
            previousSlots: [
                .init(scope: .workspace, scopeID: oldWorkspace),
                .init(scope: .surface, scopeID: oldSurface),
            ],
            activeSlots: [
                .init(scope: .workspace, scopeID: occupiedWorkspace),
                .init(scope: .surface, scopeID: newSurface),
            ]
        ) { object in
            object["workspaceId"] = occupiedWorkspace
            object["surfaceId"] = newSurface
            object["updatedAt"] = 20
        }

        #expect(patched == .rejected)
        let snapshot = try fixture.registry.snapshot(provider: "codex")
        let restored = try #require(snapshot.records.first(where: { $0.sessionID == "restored" }))
        let object = try #require(JSONSerialization.jsonObject(with: restored.json) as? [String: Any])
        #expect(object["workspaceId"] as? String == oldWorkspace)
        #expect(object["surfaceId"] as? String == oldSurface)
        #expect(Set(snapshot.activeSlots.map(\.scopeID)) == [oldWorkspace, oldSurface, occupiedWorkspace])
        #expect(!snapshot.activeSlots.contains(where: { $0.scopeID == newSurface }))
    }

    @Test("resume claims require the current surface slot to still exist")
    func resumeClaimRejectsMissingCurrentSurfaceSlot() throws {
        let fixture = try Fixture()
        let workspace = "11111111-1111-1111-1111-111111111111"
        let surface = "22222222-2222-2222-2222-222222222222"
        try fixture.registry.apply(provider: "codex", records: [
            try fixture.record(
                sessionID: "hibernated",
                updatedAt: 10,
                generation: 1,
                extra: [
                    "workspaceId": workspace,
                    "surfaceId": surface,
                    "sessionState": "hibernated",
                    "restoreAuthority": true,
                ]
            ),
        ])

        let result = try fixture.registry.patchRecordRebindingActiveSlots(
            provider: "codex",
            sessionID: "hibernated",
            updatedAt: 20,
            previousSlots: [],
            activeSlots: [.init(scope: .surface, scopeID: surface)],
            requireExistingActiveSlots: true,
            shouldMutate: { $0["sessionState"] as? String == "hibernated" }
        ) { object in
            object["sessionState"] = "restoring"
            object["updatedAt"] = 20.0
        }

        #expect(result == .rejected)
        let snapshot = try fixture.registry.snapshot(provider: "codex")
        let record = try #require(snapshot.records.first)
        let object = try #require(JSONSerialization.jsonObject(with: record.json) as? [String: Any])
        #expect(object["sessionState"] as? String == "hibernated")
        #expect(record.updatedAt == 10)
        #expect(snapshot.activeSlots.isEmpty)
    }

    @Test("resume claims preserve owned timestamps across wall-clock rollback")
    func resumeClaimUsesMonotonicOwnedTimestamp() throws {
        let fixture = try Fixture()
        let surface = "22222222-2222-2222-2222-222222222222"
        try fixture.registry.apply(
            provider: "codex",
            records: [try fixture.record(
                sessionID: "hibernated",
                updatedAt: 500,
                generation: 1,
                extra: [
                    "surfaceId": surface,
                    "sessionState": "hibernated",
                    "updatedAt": 500.0,
                ]
            )],
            activeSlots: [try fixture.slot(
                provider: "codex",
                scope: .surface,
                scopeID: surface,
                sessionID: "hibernated",
                updatedAt: 500
            )]
        )

        let result = try fixture.registry.patchRecordRebindingActiveSlots(
            provider: "codex",
            sessionID: "hibernated",
            updatedAt: 100,
            previousSlots: [],
            activeSlots: [.init(scope: .surface, scopeID: surface)],
            requireExistingActiveSlots: true,
            monotonicUpdatedAt: true,
            shouldMutate: { $0["sessionState"] as? String == "hibernated" }
        ) { object in
            object["sessionState"] = "restoring"
            object["updatedAt"] = 100.0
        }

        #expect(result == .patched)
        let snapshot = try fixture.registry.snapshot(provider: "codex")
        let record = try #require(snapshot.records.first)
        let recordObject = try #require(
            JSONSerialization.jsonObject(with: record.json) as? [String: Any]
        )
        let slot = try #require(snapshot.activeSlots.first)
        let slotObject = try #require(
            JSONSerialization.jsonObject(with: slot.json) as? [String: Any]
        )
        #expect(record.updatedAt == 500)
        #expect(recordObject["updatedAt"] as? TimeInterval == 500)
        #expect(recordObject["sessionState"] as? String == "restoring")
        #expect(slot.updatedAt == 500)
        #expect(slotObject["updatedAt"] as? TimeInterval == 500)
    }

    @Test("invalid siblings do not roll back valid members of a restore batch")
    func invalidRecordsAreIsolatedWithinRestoreBatch() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let legacyURL = fixture.directory.appendingPathComponent("codex-hook-sessions.json")
        let sessions = Dictionary(uniqueKeysWithValues: ["corrupt", "collision", "valid"].map { sessionID in
            (sessionID, fixture.object(sessionID: sessionID, updatedAt: 1).merging([
                "sessionState": "hibernated",
            ]) { _, new in new })
        })
        try fixture.legacyStore(sessions: sessions).write(to: legacyURL, options: .atomic)
        _ = try fixture.registry.refreshLegacySources([
            .init(provider: "codex", url: legacyURL),
        ])
        var database: OpaquePointer?
        #expect(sqlite3_open(fixture.registry.url.path, &database) == SQLITE_OK)
        let writer = try #require(database)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(
            writer,
            // Keep the payload valid JSON so SQLite's JSON expression index
            // accepts the fixture, while making it the wrong top-level shape
            // for a registry session record.
            "UPDATE agent_sessions SET record_json = X'5B5D' WHERE provider = 'codex' AND session_id = 'corrupt'",
            nil,
            nil,
            nil
        ) == SQLITE_OK)
        try fixture.registry.apply(
            provider: "codex",
            records: [],
            activeSlots: [try fixture.slot(
                provider: "codex",
                scope: .workspace,
                scopeID: "occupied-workspace",
                sessionID: "occupant",
                updatedAt: 2
            )]
        )

        var results: [CmuxAgentSessionRegistry.RecordRebindResult] = []
        try fixture.registry.withLegacySourceRebindBatch(
            provider: "codex",
            legacyURL: legacyURL
        ) { batch in
            for sessionID in ["corrupt", "missing", "collision", "valid"] {
                results.append(try batch.patchRecordRebindingActiveSlots(
                    provider: "codex",
                    sessionID: sessionID,
                    updatedAt: 2,
                    previousSlots: [],
                    activeSlots: sessionID == "collision"
                        ? [.init(scope: .workspace, scopeID: "occupied-workspace")]
                        : [],
                    shouldMutate: { $0["sessionState"] as? String == "hibernated" }
                ) { object in
                    object["workspaceId"] = "restored-workspace"
                    object["updatedAt"] = 2.0
                })
            }
        }

        #expect(results == [.rejected, .recordMissing, .rejected, .patched])
        let snapshot = try fixture.registry.snapshot(provider: "codex")
        let valid = try #require(snapshot.records.first { $0.sessionID == "valid" })
        let validObject = try #require(JSONSerialization.jsonObject(with: valid.json) as? [String: Any])
        #expect(validObject["workspaceId"] as? String == "restored-workspace")
    }

    @Test("a failed provider transaction rolls back without affecting another provider")
    func restoreBatchFailureIsProviderScoped() throws {
        enum ExpectedFailure: Error { case rollback }
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let codexURL = fixture.directory.appendingPathComponent("codex-hook-sessions.json")
        let claudeURL = fixture.directory.appendingPathComponent("claude-hook-sessions.json")
        try fixture.legacyStore(sessions: [
            "codex-session": fixture.object(sessionID: "codex-session", updatedAt: 1),
        ]).write(to: codexURL, options: .atomic)
        try fixture.legacyStore(sessions: [
            "claude-session": fixture.object(sessionID: "claude-session", updatedAt: 1),
        ]).write(to: claudeURL, options: .atomic)
        _ = try fixture.registry.refreshLegacySources([
            .init(provider: "codex", url: codexURL),
            .init(provider: "claude", url: claudeURL),
        ])

        #expect(throws: ExpectedFailure.self) {
            try fixture.registry.withLegacySourceRebindBatch(
                provider: "codex",
                legacyURL: codexURL
            ) { batch -> Void in
                let result = try batch.patchRecordRebindingActiveSlots(
                    provider: "codex",
                    sessionID: "codex-session",
                    updatedAt: 2,
                    previousSlots: [],
                    activeSlots: []
                ) { $0["workspaceId"] = "rolled-back-workspace" }
                #expect(result == .patched)
                throw ExpectedFailure.rollback
            }
        }
        try fixture.registry.withLegacySourceRebindBatch(
            provider: "claude",
            legacyURL: claudeURL
        ) { batch in
            let result = try batch.patchRecordRebindingActiveSlots(
                provider: "claude",
                sessionID: "claude-session",
                updatedAt: 2,
                previousSlots: [],
                activeSlots: []
            ) { $0["workspaceId"] = "committed-workspace" }
            #expect(result == .patched)
        }

        let codex = try #require(fixture.registry.snapshot(provider: "codex").records.first)
        let codexObject = try #require(JSONSerialization.jsonObject(with: codex.json) as? [String: Any])
        #expect(codexObject["workspaceId"] as? String == "11111111-1111-1111-1111-111111111111")
        let claude = try #require(fixture.registry.snapshot(provider: "claude").records.first)
        let claudeObject = try #require(JSONSerialization.jsonObject(with: claude.json) as? [String: Any])
        #expect(claudeObject["workspaceId"] as? String == "committed-workspace")
    }

    @Test("stale previous slots owned by another session survive rebind")
    func stalePreviousSlotOwnedByAnotherSessionSurvivesRebind() throws {
        let fixture = try Fixture()
        let oldWorkspace = "11111111-1111-1111-1111-111111111111"
        let oldSurface = "22222222-2222-2222-2222-222222222222"
        let newWorkspace = "33333333-3333-3333-3333-333333333333"
        let newSurface = "44444444-4444-4444-4444-444444444444"
        try fixture.registry.apply(
            provider: "codex",
            records: [try fixture.record(sessionID: "restored", updatedAt: 10, generation: 1)],
            activeSlots: [
                try fixture.slot(
                    provider: "codex",
                    scope: .workspace,
                    scopeID: oldWorkspace,
                    sessionID: "new-owner",
                    updatedAt: 15
                ),
                try fixture.slot(
                    provider: "codex",
                    scope: .surface,
                    scopeID: oldSurface,
                    sessionID: "restored",
                    updatedAt: 10
                ),
            ]
        )

        let patched = try fixture.registry.patchRecordRebindingActiveSlots(
            provider: "codex",
            sessionID: "restored",
            updatedAt: 20,
            previousSlots: [
                .init(scope: .workspace, scopeID: oldWorkspace),
                .init(scope: .surface, scopeID: oldSurface),
            ],
            activeSlots: [
                .init(scope: .workspace, scopeID: newWorkspace),
                .init(scope: .surface, scopeID: newSurface),
            ]
        ) { object in
            object["workspaceId"] = newWorkspace
            object["surfaceId"] = newSurface
            object["updatedAt"] = 20
        }

        #expect(patched == .patched)
        let snapshot = try fixture.registry.snapshot(provider: "codex")
        #expect(snapshot.activeSlots.first(where: { $0.scopeID == oldWorkspace })?.sessionID == "new-owner")
        #expect(!snapshot.activeSlots.contains(where: { $0.scopeID == oldSurface }))
        #expect(snapshot.activeSlots.first(where: { $0.scopeID == newWorkspace })?.sessionID == "restored")
        #expect(snapshot.activeSlots.first(where: { $0.scopeID == newSurface })?.sessionID == "restored")
    }

    @Test("concurrent stale rebinds serialize through the record fence")
    func concurrentStaleRebindsSerializeThroughRecordFence() async throws {
        let fixture = try Fixture(busyTimeoutMilliseconds: 25)
        let oldWorkspace = "11111111-1111-1111-1111-111111111111"
        let oldSurface = "22222222-2222-2222-2222-222222222222"
        try fixture.registry.apply(
            provider: "codex",
            records: [try fixture.record(sessionID: "restored", updatedAt: 10, generation: 1)],
            activeSlots: [
                try fixture.slot(
                    provider: "codex",
                    scope: .workspace,
                    scopeID: oldWorkspace,
                    sessionID: "restored",
                    updatedAt: 10
                ),
                try fixture.slot(
                    provider: "codex",
                    scope: .surface,
                    scopeID: oldSurface,
                    sessionID: "restored",
                    updatedAt: 10
                ),
            ]
        )
        let registry = fixture.registry
        let targets = [
            ("33333333-3333-3333-3333-333333333333", "44444444-4444-4444-4444-444444444444"),
            ("55555555-5555-5555-5555-555555555555", "66666666-6666-6666-6666-666666666666"),
        ]

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for (workspace, surface) in targets {
                group.addTask {
                    (try? registry.patchRecordRebindingActiveSlots(
                        provider: "codex",
                        sessionID: "restored",
                        updatedAt: 20,
                        previousSlots: [
                            .init(scope: .workspace, scopeID: oldWorkspace),
                            .init(scope: .surface, scopeID: oldSurface),
                        ],
                        activeSlots: [
                            .init(scope: .workspace, scopeID: workspace),
                            .init(scope: .surface, scopeID: surface),
                        ],
                        shouldMutate: {
                            $0["workspaceId"] as? String == oldWorkspace
                                && $0["surfaceId"] as? String == oldSurface
                        }
                    ) { object in
                        object["workspaceId"] = workspace
                        object["surfaceId"] = surface
                        object["updatedAt"] = 20
                    }) == .patched
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }

        #expect(results.filter { $0 }.count == 1)
        let snapshot = try fixture.registry.snapshot(provider: "codex")
        let record = try #require(snapshot.records.first)
        let object = try #require(JSONSerialization.jsonObject(with: record.json) as? [String: Any])
        let workspace = try #require(object["workspaceId"] as? String)
        let surface = try #require(object["surfaceId"] as? String)
        #expect(Set(snapshot.activeSlots.map(\.scopeID)) == [workspace, surface])
        #expect(snapshot.activeSlots.allSatisfy { $0.sessionID == "restored" })
    }

    @Test("targeted rebind stays bounded with ten thousand other sessions")
    func targetedRebindPerformance() throws {
        let fixture = try Fixture()
        let records = try (0..<10_000).map { index in
            try fixture.record(sessionID: "session-\(index)", updatedAt: Double(index), generation: 1)
        }
        try fixture.registry.apply(provider: "codex", records: records)

        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            let patched = try fixture.registry.patchRecordRebindingActiveSlots(
                provider: "codex",
                sessionID: "session-5000",
                updatedAt: 20_000,
                previousSlots: [],
                activeSlots: [
                    .init(scope: .workspace, scopeID: "new-workspace"),
                    .init(scope: .surface, scopeID: "new-surface"),
                ]
            ) { object in
                object["workspaceId"] = "new-workspace"
                object["surfaceId"] = "new-surface"
                object["updatedAt"] = 20_000
            }
            #expect(patched == .patched)
        }
        #expect(elapsed < .seconds(1))
    }

    @Test("one thousand pre-imported hibernated rows adopt sequentially within a bounded interval")
    func restoredHibernationBatchAdoptionPerformance() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let legacyURL = fixture.directory.appendingPathComponent("codex-hook-sessions.json")
        var sessions: [String: Any] = [:]
        var workspaceSlots: [String: Any] = [:]
        var surfaceSlots: [String: Any] = [:]
        for index in 0..<1_000 {
            let sessionID = "session-\(index)"
            let oldWorkspace = "old-workspace-\(index)"
            let oldSurface = "old-surface-\(index)"
            sessions[sessionID] = [
                "sessionId": sessionID,
                "workspaceId": oldWorkspace,
                "surfaceId": oldSurface,
                "sessionState": "hibernated",
                "restoreAuthority": true,
                "startedAt": 1.0,
                "updatedAt": 2.0,
            ]
            let slot: [String: Any] = ["sessionId": sessionID, "updatedAt": 2.0]
            workspaceSlots[oldWorkspace] = slot
            surfaceSlots[oldSurface] = slot
        }
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": sessions,
            "activeSessionsByWorkspace": workspaceSlots,
            "activeSessionsBySurface": surfaceSlots,
        ], options: [.sortedKeys]).write(to: legacyURL, options: .atomic)
        let preflight = try fixture.registry.refreshLegacySources([
            .init(provider: "codex", url: legacyURL),
        ])
        #expect(preflight.refreshedProviders == ["codex"])

        let elapsed = try ContinuousClock().measure {
            try fixture.registry.withLegacySourceRebindBatch(
                provider: "codex",
                legacyURL: legacyURL
            ) { batch in
                for index in 0..<1_000 {
                    let sessionID = "session-\(index)"
                    let oldWorkspace = "old-workspace-\(index)"
                    let oldSurface = "old-surface-\(index)"
                    let newWorkspace = "new-workspace-\(index)"
                    let newSurface = "new-surface-\(index)"
                    let result = try batch.patchRecordRebindingActiveSlots(
                        provider: "codex",
                        sessionID: sessionID,
                        updatedAt: 3.0,
                        previousSlots: [
                            .init(scope: .workspace, scopeID: oldWorkspace),
                            .init(scope: .surface, scopeID: oldSurface),
                        ],
                        activeSlots: [
                            .init(scope: .workspace, scopeID: newWorkspace),
                            .init(scope: .surface, scopeID: newSurface),
                        ],
                        shouldMutate: {
                            $0["sessionState"] as? String == "hibernated"
                                && $0["workspaceId"] as? String == oldWorkspace
                                && $0["surfaceId"] as? String == oldSurface
                        }
                    ) { object in
                        object["workspaceId"] = newWorkspace
                        object["surfaceId"] = newSurface
                        object["updatedAt"] = 3.0
                    }
                    #expect(result == .patched)
                }
            }
        }

        print("restore sequential 1000-row adoption elapsed: \(elapsed)")
        #expect(elapsed < .seconds(1))
        let snapshot = try fixture.registry.snapshot(provider: "codex")
        #expect(snapshot.records.count == 1_000)
        #expect(snapshot.activeSlots.count == 2_000)
        #expect(snapshot.activeSlots.allSatisfy { $0.scopeID.hasPrefix("new-") })
    }

    @Test("targeted rebind spends only one busy timeout waiting for a writer")
    func targetedRebindContentionIsBounded() throws {
        let fixture = try Fixture(busyTimeoutMilliseconds: 5)
        try fixture.registry.apply(provider: "codex", records: [
            try fixture.record(sessionID: "blocked", updatedAt: 10, generation: 1),
        ])
        var database: OpaquePointer?
        #expect(sqlite3_open(fixture.registry.url.path, &database) == SQLITE_OK)
        let writer = try #require(database)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(throws: (any Error).self) {
                try fixture.registry.patchRecordRebindingActiveSlots(
                    provider: "codex",
                    sessionID: "blocked",
                    updatedAt: 20,
                    previousSlots: [],
                    activeSlots: []
                ) { object in
                    object["updatedAt"] = 20
                }
            }
        }

        #expect(elapsed < .seconds(1))
    }

    @Test("one thousand indexed session rows load within a bounded interval")
    func indexedSnapshotPerformance() throws {
        let fixture = try Fixture()
        let records = try (0..<1_000).map { index in
            try fixture.record(sessionID: "session-\(index)", updatedAt: Double(index), generation: 1)
        }
        try fixture.registry.apply(provider: "codex", records: records)

        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            let snapshot = try fixture.registry.snapshot(provider: "codex")
            #expect(snapshot.records.count == 1_000)
        }
        #expect(elapsed < .seconds(1))
    }

    @Test("disjoint hook mutations do not lose writes at the retention boundary")
    func disjointMutationsAtRetentionBoundary() async throws {
        let fixture = try Fixture(busyTimeoutMilliseconds: 25)
        let records = try (0..<10_000).map { index in
            try fixture.record(sessionID: "session-\(index)", updatedAt: Double(index), generation: 1)
        }
        try fixture.registry.apply(provider: "codex", records: records)
        let registry = fixture.registry

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<16 {
                group.addTask {
                    do {
                        return try registry.mutateSnapshot(provider: "codex") { snapshot in
                            guard let recordIndex = snapshot.records.firstIndex(where: {
                                $0.sessionID == "session-\(index)"
                            }) else { return false }
                            snapshot.records[recordIndex].updatedAt = 20_000 + Double(index)
                            return true
                        }
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }

        #expect(successes == 16)
        let stored = try fixture.registry.snapshot(provider: "codex")
        let updated = stored.records.filter { $0.updatedAt >= 20_000 }
        #expect(updated.count == 16)
    }

    @Test("concurrent inserts replay retention decisions from the latest membership")
    func concurrentInsertsReplayRetentionDecision() async throws {
        let fixture = try Fixture(busyTimeoutMilliseconds: 25)
        let records = try (0..<9_999).map { index in
            try fixture.record(sessionID: "session-\(index)", updatedAt: Double(index), generation: 1)
        }
        try fixture.registry.apply(provider: "codex", records: records)
        let additions = try (0..<2).map { index in
            try fixture.record(
                sessionID: "concurrent-\(index)",
                updatedAt: 20_000 + Double(index),
                generation: 1
            )
        }
        let registry = fixture.registry
        let rendezvous = FirstMutationRendezvous(participantCount: additions.count)

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for addition in additions {
                group.addTask {
                    var isFirstAttempt = true
                    do {
                        return try registry.mutateSnapshot(provider: "codex") { snapshot in
                            if isFirstAttempt {
                                isFirstAttempt = false
                                rendezvous.wait()
                            }
                            snapshot.records.append(addition)
                            if snapshot.records.count > 10_000,
                               let oldest = snapshot.records.min(by: { $0.updatedAt < $1.updatedAt }) {
                                snapshot.records.removeAll { $0.sessionID == oldest.sessionID }
                            }
                            return true
                        }
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }

        #expect(successes == additions.count)
        let stored = try fixture.registry.snapshot(provider: "codex")
        #expect(stored.records.count == 10_000)
        #expect(Set(stored.records.map(\.sessionID)).isSuperset(of: additions.map(\.sessionID)))
    }

    @Test("same-session mutations replay without losing increments")
    func sameSessionMutationsReplay() async throws {
        let fixture = try Fixture(busyTimeoutMilliseconds: 25)
        try fixture.registry.apply(provider: "codex", records: [
            try fixture.record(sessionID: "shared", updatedAt: 0, generation: 1),
        ])
        let registry = fixture.registry
        let mutationCount = 8
        let rendezvous = FirstMutationRendezvous(participantCount: mutationCount)

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<mutationCount {
                group.addTask {
                    var isFirstAttempt = true
                    do {
                        return try registry.mutateSnapshot(provider: "codex") { snapshot in
                            if isFirstAttempt {
                                isFirstAttempt = false
                                rendezvous.wait()
                            }
                            guard let index = snapshot.records.firstIndex(where: {
                                $0.sessionID == "shared"
                            }) else { return false }
                            snapshot.records[index].updatedAt += 1
                            return true
                        }
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }

        #expect(successes == mutationCount)
        let stored = try #require(fixture.registry.snapshot(provider: "codex").records.first)
        #expect(stored.updatedAt == Double(mutationCount))
    }

    @Test("mutation replay has one bounded busy-timeout budget")
    func mutationReplayContentionIsBounded() throws {
        let fixture = try Fixture(busyTimeoutMilliseconds: 1)
        try fixture.registry.apply(provider: "codex", records: [
            try fixture.record(sessionID: "blocked", updatedAt: 0, generation: 1),
        ])
        var database: OpaquePointer?
        #expect(sqlite3_open(fixture.registry.url.path, &database) == SQLITE_OK)
        let writer = try #require(database)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(throws: (any Error).self) {
                try fixture.registry.mutateSnapshot(provider: "codex") { snapshot in
                    snapshot.records[0].updatedAt += 1
                }
            }
        }

        #expect(elapsed < .seconds(1))
    }

    @Test("WAL snapshots stay readable while another connection owns the writer lock")
    func snapshotDoesNotJoinWriterContention() throws {
        let fixture = try Fixture(busyTimeoutMilliseconds: 10)
        try fixture.registry.apply(provider: "codex", records: [
            try fixture.record(sessionID: "committed", updatedAt: 1, generation: 1),
        ])

        var database: OpaquePointer?
        #expect(sqlite3_open(fixture.registry.url.path, &database) == SQLITE_OK)
        let writer = try #require(database)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }

        let snapshot = try fixture.registry.snapshot(provider: "codex")
        #expect(snapshot.records.map(\.sessionID) == ["committed"])
    }

    @Test("malformed registry rows fail instead of returning a partial snapshot")
    func malformedRowsFailClosed() throws {
        let fixture = try Fixture()
        _ = try fixture.registry.snapshot(provider: "codex")
        var database: OpaquePointer?
        #expect(sqlite3_open(fixture.registry.url.path, &database) == SQLITE_OK)
        let writer = try #require(database)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(
            writer,
            """
            INSERT INTO agent_active_slots (
                provider, scope, scope_id, session_id, updated_at, writer_generation, record_json
            ) VALUES ('codex', 'future-scope', 'scope', 'session', 1, 1, X'7B7D')
            """,
            nil,
            nil,
            nil
        ) == SQLITE_OK)

        #expect(throws: (any Error).self) {
            try fixture.registry.snapshot(provider: "codex")
        }
    }

    @Test("registry storage repairs an existing state directory to owner-only access")
    func registryRepairsStateDirectoryPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-registry-permissions-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: stateDirectory.path
        )
        let registry = CmuxAgentSessionRegistry(
            url: stateDirectory.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )

        _ = try registry.snapshot(provider: "codex")

        let attributes = try FileManager.default.attributesOfItem(atPath: stateDirectory.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o700)
    }

    @Test("explicit registry paths preserve existing parent directory permissions")
    func registryPreservesExistingParentDirectoryPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-registry-shared-parent-\(UUID().uuidString)", isDirectory: true)
        let sharedDirectory = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: sharedDirectory.path
        )
        let registry = CmuxAgentSessionRegistry(
            url: sharedDirectory.appendingPathComponent("custom-agent-sessions.sqlite3")
        )

        _ = try registry.snapshot(provider: "codex")

        let attributes = try FileManager.default.attributesOfItem(atPath: sharedDirectory.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o755)
    }

    private struct Fixture {
        let directory: URL
        let registry: CmuxAgentSessionRegistry

        init(busyTimeoutMilliseconds: Int32 = 100) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-agent-registry-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            registry = CmuxAgentSessionRegistry(
                url: directory.appendingPathComponent(CmuxAgentSessionRegistry.filename),
                busyTimeoutMilliseconds: busyTimeoutMilliseconds
            )
        }

        func object(sessionID: String, updatedAt: TimeInterval) -> [String: Any] {
            [
                "sessionId": sessionID,
                "workspaceId": "11111111-1111-1111-1111-111111111111",
                "surfaceId": "22222222-2222-2222-2222-222222222222",
                "startedAt": 1,
                "updatedAt": updatedAt,
            ]
        }

        func record(
            sessionID: String,
            updatedAt: TimeInterval,
            generation: Int,
            extra: [String: Any] = [:]
        ) throws -> CmuxAgentSessionRegistry.Record {
            let object = object(sessionID: sessionID, updatedAt: updatedAt).merging(extra) { _, new in new }
            return CmuxAgentSessionRegistry.Record(
                provider: "test",
                sessionID: sessionID,
                updatedAt: updatedAt,
                writerGeneration: generation,
                json: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            )
        }

        func slot(
            provider: String,
            scope: CmuxAgentSessionRegistry.Scope,
            scopeID: String,
            sessionID: String,
            updatedAt: TimeInterval,
            generation: Int = CmuxAgentSessionRegistry.currentWriterGeneration,
            extra: [String: Any] = [:]
        ) throws -> CmuxAgentSessionRegistry.ActiveSlot {
            let object: [String: Any] = [
                "sessionId": sessionID,
                "updatedAt": updatedAt,
            ].merging(extra) { _, new in new }
            return CmuxAgentSessionRegistry.ActiveSlot(
                provider: provider,
                scope: scope,
                scopeID: scopeID,
                sessionID: sessionID,
                updatedAt: updatedAt,
                writerGeneration: generation,
                json: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            )
        }

        func legacyStore(sessions: [String: [String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["version": 2, "sessions": sessions], options: [.sortedKeys])
        }
    }

    private final class FirstMutationRendezvous: @unchecked Sendable {
        private let condition = NSCondition()
        private var remaining: Int

        init(participantCount: Int) {
            remaining = participantCount
        }

        func wait() {
            condition.lock()
            remaining -= 1
            if remaining == 0 {
                condition.broadcast()
            } else {
                let deadline = Date(timeIntervalSinceNow: 1)
                while remaining > 0, condition.wait(until: deadline) {}
            }
            condition.unlock()
        }
    }
}

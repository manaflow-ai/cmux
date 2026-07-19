import Foundation
import Darwin
import SQLite3
import Testing
@testable import CmuxFoundation

@Suite("Agent session registry hook hot path", .serialized)
struct CmuxAgentSessionRegistryHookHotPathTests {
    private final class Fixture: @unchecked Sendable {
        let registry: CmuxAgentSessionRegistry
        let directory: URL
        let legacyURL: URL

        init(directory: URL) {
            self.directory = directory
            registry = CmuxAgentSessionRegistry(
                url: directory.appendingPathComponent(CmuxAgentSessionRegistry.filename),
                busyTimeoutMilliseconds: 250
            )
            legacyURL = directory.appendingPathComponent("agent-hook-sessions.json")
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("exact hook mutation reads one record and at most four slots at ten thousand rows")
    func exactMutationHasConstantRowCost() throws {
        let fixture = try makeFixture()
        let now = Date().timeIntervalSince1970
        let records = try (0..<10_000).map { index in
            try record(
                provider: "codex",
                sessionID: String(format: "session-%05d", index),
                workspaceID: "workspace-\(index)",
                surfaceID: "surface-\(index)",
                updatedAt: now
            )
        }
        try fixture.registry.apply(provider: "codex", records: records)
        let targetID = "session-05000"
        let targetSlots = try slots(
            provider: "codex",
            sessionID: targetID,
            workspaceID: "workspace-5000",
            surfaceID: "surface-5000",
            updatedAt: now
        )
        let otherSlots = try slots(
            provider: "codex",
            sessionID: "session-05001",
            workspaceID: "destination-workspace",
            surfaceID: "destination-surface",
            updatedAt: now
        )
        try fixture.registry.apply(
            provider: "codex",
            records: [],
            activeSlots: targetSlots + otherSlots
        )

        let result = try fixture.registry.mutateHookSession(
            provider: "codex",
            sessionID: targetID,
            activeSlots: [
                .init(scope: .workspace, scopeID: "destination-workspace"),
                .init(scope: .surface, scopeID: "destination-surface"),
            ],
            now: now
        ) { snapshot in
            var stored = try #require(snapshot.records.first)
            var object = try #require(
                JSONSerialization.jsonObject(with: stored.json) as? [String: Any]
            )
            object["counter"] = 1
            stored.updatedAt += 1
            object["updatedAt"] = stored.updatedAt
            stored.json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            snapshot.records = [stored]
        }

        #expect(result.recordsRead == 1)
        #expect(result.slotsRead == 4)
        #expect(result.recordsWritten == 1)
        #expect(result.slotsWritten == 0)
        #expect(try fixture.registry.snapshot(provider: "codex").records.count == 10_000)
    }

    @Test("running lookup skips ten thousand inactive rows in one workspace")
    func runningLookupUsesRuntimeStateIndex() throws {
        let fixture = try makeFixture()
        let records = try (0..<10_000).map { index in
            try record(
                provider: "claude",
                sessionID: String(format: "inactive-%05d", index),
                workspaceID: "shared-workspace",
                surfaceID: "surface-\(index)",
                updatedAt: TimeInterval(index),
                extra: ["runtimeStatus": "idle"]
            )
        }
        try fixture.registry.apply(provider: "claude", records: records)
        try fixture.registry.apply(
            provider: "claude",
            records: [try record(
                provider: "claude",
                sessionID: "running",
                workspaceID: "shared-workspace",
                surfaceID: "running-surface",
                updatedAt: 10_001
            )]
        )

        let running = try fixture.registry.hookRunningRecords(
            provider: "claude",
            workspaceID: "shared-workspace",
            surfaceID: nil
        )
        #expect(running.map(\.sessionID) == ["running"])
    }

    @Test("storage preflight reports encoded lengths without loading snapshots")
    func storagePreflightReportsExactLengths() throws {
        let fixture = try makeFixture()
        let small = try record(
            provider: "pi",
            sessionID: "small",
            workspaceID: "workspace-small",
            surfaceID: "surface-small",
            updatedAt: 1
        )
        let large = try record(
            provider: "pi",
            sessionID: "large",
            workspaceID: "workspace-large",
            surfaceID: "surface-large",
            updatedAt: 2,
            extra: ["payload": String(repeating: "x", count: 4_096)]
        )
        let activeSlots = try slots(
            provider: "pi",
            sessionID: "large",
            workspaceID: "workspace-large",
            surfaceID: "surface-large",
            updatedAt: 2
        )
        try fixture.registry.apply(
            provider: "pi",
            records: [small, large],
            activeSlots: activeSlots
        )

        let metrics = try fixture.registry.hookStorageMetrics(provider: "pi")
        #expect(metrics.recordCount == 2)
        #expect(metrics.recordBytes == Int64(small.json.count + large.json.count))
        #expect(metrics.activeSlotBytes == Int64(activeSlots.reduce(0) { $0 + $1.json.count }))
        #expect(metrics.largestRecordSessionID == "large")
        #expect(metrics.largestRecordBytes == Int64(large.json.count))
        #expect(metrics.totalBytes == metrics.recordBytes + metrics.activeSlotBytes)
    }

    @Test("bounded recent reads retain active owners before newest inactive history")
    func boundedRecentRecordsRetainActiveOwners() throws {
        let fixture = try makeFixture()
        let provider = "recent"
        var records: [CmuxAgentSessionRegistry.Record] = []
        var activeSlots: [CmuxAgentSessionRegistry.ActiveSlot] = []
        for index in 0..<2 {
            let sessionID = "active-old-\(index)"
            records.append(try record(
                provider: provider,
                sessionID: sessionID,
                workspaceID: "workspace-\(sessionID)",
                surfaceID: "surface-\(sessionID)",
                updatedAt: TimeInterval(index)
            ))
            activeSlots.append(contentsOf: try slots(
                provider: provider,
                sessionID: sessionID,
                workspaceID: "workspace-\(sessionID)",
                surfaceID: "surface-\(sessionID)",
                updatedAt: TimeInterval(index)
            ))
        }
        for index in 2..<10 {
            records.append(try record(
                provider: provider,
                sessionID: "inactive-\(index)",
                workspaceID: "workspace-inactive-\(index)",
                surfaceID: "surface-inactive-\(index)",
                updatedAt: TimeInterval(index)
            ))
        }
        try fixture.registry.apply(
            provider: provider,
            records: records,
            activeSlots: activeSlots
        )

        let selected = try fixture.registry.hookBoundedRecentRecords(
            provider: provider,
            maximumRecords: 3
        )
        #expect(selected.map(\.sessionID) == [
            "active-old-1",
            "active-old-0",
            "inactive-9",
        ])
        #expect(
            try fixture.registry.hookBoundedRecentRecords(
                provider: provider,
                maximumRecords: 3
            ).map(\.sessionID) == selected.map(\.sessionID)
        )

        var countFailure: CmuxAgentSessionRegistry.HookSnapshotLimitError?
        do {
            _ = try fixture.registry.hookBoundedRecentRecords(
                provider: provider,
                maximumRecords: 1
            )
        } catch let error as CmuxAgentSessionRegistry.HookSnapshotLimitError {
            countFailure = error
        }
        let countError = try #require(countFailure)
        #expect(countError.scope == .records)
        #expect(countError.observed == 2)

        let activeBytes = records
            .filter { $0.sessionID.hasPrefix("active-old-") }
            .reduce(Int64(0)) { $0 + Int64($1.json.count) }
        let newestInactive = try #require(
            records.first { $0.sessionID == "inactive-9" }
        )
        let exactBudget = activeBytes + Int64(newestInactive.json.count)
        #expect(
            try fixture.registry.hookBoundedRecentRecords(
                provider: provider,
                maximumRecords: 3,
                maximumBytes: exactBudget
            ).map(\.sessionID) == selected.map(\.sessionID)
        )
        #expect(
            try fixture.registry.hookBoundedRecentRecords(
                provider: provider,
                maximumRecords: 3,
                maximumBytes: exactBudget - 1
            ).map(\.sessionID) == ["active-old-1", "active-old-0"]
        )

        var byteFailure: CmuxAgentSessionRegistry.HookSnapshotLimitError?
        do {
            _ = try fixture.registry.hookBoundedRecentRecords(
                provider: provider,
                maximumRecords: 3,
                maximumBytes: activeBytes - 1
            )
        } catch let error as CmuxAgentSessionRegistry.HookSnapshotLimitError {
            byteFailure = error
        }
        #expect(try #require(byteFailure).scope == .providerBytes)

        let largeProvider = "recent-large"
        let payload = String(repeating: "x", count: 256 * 1_024)
        let largeRecords = try (0..<32).map { index in
            let sessionID = String(format: "inactive-%02d", index)
            let object: [String: Any] = [
                "sessionId": sessionID,
                "updatedAt": TimeInterval(index),
                "payload": payload,
            ]
            return CmuxAgentSessionRegistry.Record(
                provider: largeProvider,
                sessionID: sessionID,
                updatedAt: TimeInterval(index),
                json: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            )
        }
        try fixture.registry.apply(
            provider: largeProvider,
            records: largeRecords,
            activeSlots: []
        )
        let newestLargeRecord = try #require(largeRecords.last)
        #expect(
            try fixture.registry.hookBoundedRecentRecords(
                provider: largeProvider,
                maximumRecords: largeRecords.count,
                maximumBytes: Int64(newestLargeRecord.json.count)
            ).map(\.sessionID) == [newestLargeRecord.sessionID]
        )
    }

    @Test("bounded list snapshots return exact per-provider counts and top K")
    func boundedListSnapshotsAreExactAcrossProviders() throws {
        let fixture = try makeFixture()
        try fixture.registry.apply(
            provider: "codex",
            records: try (0..<5).map { index in
                try record(
                    provider: "codex",
                    sessionID: "codex-\(index)",
                    workspaceID: "codex-workspace-\(index)",
                    surfaceID: "codex-surface-\(index)",
                    updatedAt: TimeInterval(index)
                )
            }
        )
        try fixture.registry.apply(
            provider: "claude",
            records: try (0..<3).map { index in
                try record(
                    provider: "claude",
                    sessionID: "claude-\(index)",
                    workspaceID: "claude-workspace-\(index)",
                    surfaceID: "claude-surface-\(index)",
                    updatedAt: TimeInterval(index)
                )
            }
        )

        let snapshots = try fixture.registry.boundedRecentSnapshotsImportingLegacy(
            sources: [
                .init(provider: "codex", url: fixture.directory.appendingPathComponent("codex.json")),
                .init(provider: "claude", url: fixture.directory.appendingPathComponent("claude.json")),
            ],
            maximumRecordsPerProvider: 2
        )

        #expect(snapshots["codex"]?.totalRecordCount == 5)
        #expect(snapshots["codex"]?.snapshot.records.map(\.sessionID) == ["codex-4", "codex-3"])
        #expect(snapshots["claude"]?.totalRecordCount == 3)
        #expect(snapshots["claude"]?.snapshot.records.map(\.sessionID) == ["claude-2", "claude-1"])
    }

    @Test("global bounded list materializes one shared top K across providers")
    func globallyBoundedListSnapshotsShareOneCandidateBudget() throws {
        let fixture = try makeFixture()
        let providers = ["alpha", "beta", "gamma", "delta"]
        for (providerIndex, provider) in providers.enumerated() {
            try fixture.registry.apply(
                provider: provider,
                records: try (0..<5).map { recordIndex in
                    try record(
                        provider: provider,
                        sessionID: "\(provider)-\(recordIndex)",
                        workspaceID: "\(provider)-workspace-\(recordIndex)",
                        surfaceID: "\(provider)-surface-\(recordIndex)",
                        updatedAt: TimeInterval(recordIndex * providers.count + providerIndex)
                    )
                }
            )
        }

        let snapshots = try fixture.registry
            .globallyBoundedRecentSnapshotsImportingAdmittedLegacy(
                sources: providers.map {
                    .init(
                        provider: $0,
                        url: fixture.directory.appendingPathComponent("\($0).json")
                    )
                },
                admissions: [],
                maximumRecords: 3
            )

        #expect(snapshots.values.reduce(0) { $0 + $1.snapshot.records.count } == 3)
        #expect(snapshots.values.reduce(0) { $0 + $1.totalRecordCount } == 20)
        #expect(snapshots.mapValues(\.totalRecordCount) == Dictionary(
            uniqueKeysWithValues: providers.map { ($0, 5) }
        ))
        #expect(Set(snapshots.flatMap { provider, snapshot in
            snapshot.snapshot.records.map { "\(provider):\($0.sessionID)" }
        }) == Set([
            "beta:beta-4",
            "gamma:gamma-4",
            "delta:delta-4",
        ]))
    }

    @Test("bounded validation selection and count share one WAL snapshot")
    func boundedListValidationAndSelectionAreAtomic() throws {
        let fixture = try makeFixture()
        let provider = "atomic-bounded-list"
        try fixture.registry.apply(provider: provider, records: [
            try record(
                provider: provider,
                sessionID: "original-old",
                workspaceID: "workspace-old",
                surfaceID: "surface-old",
                updatedAt: 1
            ),
            try record(
                provider: provider,
                sessionID: "original-new",
                workspaceID: "workspace-new",
                surfaceID: "surface-new",
                updatedAt: 2
            ),
        ])
        var insertedConcurrentRow = false

        let snapshots = try fixture.registry.boundedRecentSnapshotsImportingLegacy(
            sources: [.init(
                provider: provider,
                url: fixture.directory.appendingPathComponent("atomic.json")
            )],
            maximumRecordsPerProvider: 1,
            validateRecord: { _, _ in
                guard !insertedConcurrentRow else { return }
                insertedConcurrentRow = true
                try fixture.registry.apply(provider: provider, records: [try record(
                    provider: provider,
                    sessionID: "concurrent-newest",
                    workspaceID: "workspace-concurrent",
                    surfaceID: "surface-concurrent",
                    updatedAt: 3
                )])
            }
        )

        #expect(insertedConcurrentRow)
        #expect(snapshots[provider]?.totalRecordCount == 2)
        #expect(snapshots[provider]?.snapshot.records.map(\.sessionID) == ["original-new"])
        #expect(try fixture.registry.snapshot(provider: provider).records.count == 3)
    }

    @Test("bounded list ordering uses the projected active run timestamp")
    func boundedListOrderingUsesProjectedRun() throws {
        let fixture = try makeFixture()
        let provider = "projected-run"
        let staleActiveRun = try record(
            provider: provider,
            sessionID: "row-newer-run-older",
            workspaceID: "workspace-stale",
            surfaceID: "surface-stale",
            updatedAt: 100,
            extra: [
                "activeRunId": "active-stale",
                "runs": [[
                    "runId": "active-stale",
                    "restoreAuthority": true,
                    "startedAt": 1.0,
                    "updatedAt": 1.0,
                ]],
            ]
        )
        let recentRun = try record(
            provider: provider,
            sessionID: "row-older-run-newer",
            workspaceID: "workspace-recent",
            surfaceID: "surface-recent",
            updatedAt: 10,
            extra: [
                "activeRunId": "active-recent",
                "runs": [[
                    "runId": "active-recent",
                    "restoreAuthority": true,
                    "startedAt": 10.0,
                    "updatedAt": 10.0,
                ]],
            ]
        )
        try fixture.registry.apply(provider: provider, records: [staleActiveRun, recentRun])

        let bounded = try fixture.registry.hookBoundedRecentSnapshot(
            provider: provider,
            maximumRecords: 1
        )

        #expect(bounded.totalRecordCount == 2)
        #expect(bounded.snapshot.records.map(\.sessionID) == ["row-older-run-newer"])
    }

    @Test("bounded list slots never attach an omitted owner to a retained session")
    func boundedListSlotsRequireSelectedOwner() throws {
        let fixture = try makeFixture()
        let provider = "displaced-owner"
        let older = try record(
            provider: provider,
            sessionID: "older-owner",
            workspaceID: "shared-workspace",
            surfaceID: "older-surface",
            updatedAt: 1
        )
        let newer = try record(
            provider: provider,
            sessionID: "newer-session",
            workspaceID: "shared-workspace",
            surfaceID: "newer-surface",
            updatedAt: 2
        )
        let workspaceSlot = try #require(try slots(
            provider: provider,
            sessionID: older.sessionID,
            workspaceID: "shared-workspace",
            surfaceID: "older-surface",
            updatedAt: 1
        ).first { $0.scope == .workspace })
        try fixture.registry.apply(
            provider: provider,
            records: [older, newer],
            activeSlots: [workspaceSlot]
        )

        let one = try fixture.registry.hookBoundedRecentSnapshot(
            provider: provider,
            maximumRecords: 1
        )
        #expect(one.snapshot.records.map(\.sessionID) == ["newer-session"])
        #expect(one.snapshot.activeSlots.isEmpty)

        let two = try fixture.registry.hookBoundedRecentSnapshot(
            provider: provider,
            maximumRecords: 2
        )
        #expect(two.snapshot.activeSlots.map(\.sessionID) == ["older-owner"])
    }

    @Test("bounded list slots reject canonical metadata and JSON scope disagreement")
    func boundedListSlotsValidateCanonicalProjectionMetadata() throws {
        let fixture = try makeFixture()
        let provider = "slot-metadata"
        let sessionID = "session"
        let stored = try record(
            provider: provider,
            sessionID: sessionID,
            workspaceID: "workspace",
            surfaceID: "surface",
            updatedAt: 1
        )
        try fixture.registry.apply(
            provider: provider,
            records: [stored],
            activeSlots: try slots(
                provider: provider,
                sessionID: sessionID,
                workspaceID: "workspace",
                surfaceID: "surface",
                updatedAt: 1
            )
        )
        try overwriteWorkspaceProjectionMetadata(
            registryURL: fixture.registry.url,
            provider: provider,
            sessionID: sessionID,
            workspaceID: "different-workspace"
        )

        var failure: CmuxAgentSessionRegistry.HookListProjectionValidationError?
        do {
            _ = try fixture.registry.hookBoundedRecentSnapshot(
                provider: provider,
                maximumRecords: 1
            )
        } catch let error as CmuxAgentSessionRegistry.HookListProjectionValidationError {
            failure = error
        }

        let error = try #require(failure)
        #expect(error.provider == provider)
    }

    @Test("bounded list identity validation matches Swift canonical equivalence")
    func boundedListIdentityUsesCanonicalUnicodeEquivalence() throws {
        let fixture = try makeFixture()
        let provider = "unicode-identity"
        let storedSessionID = "session-\u{00E9}"
        let projectedSessionID = "session-e\u{0301}"
        let storedWorkspaceID = "workspace-\u{00E9}"
        let projectedWorkspaceID = "workspace-e\u{0301}"
        let storedSurfaceID = "surface-\u{00E9}"
        let projectedSurfaceID = "surface-e\u{0301}"
        #expect(storedSessionID == projectedSessionID)
        #expect(storedWorkspaceID == projectedWorkspaceID)
        #expect(storedSurfaceID == projectedSurfaceID)

        let record = CmuxAgentSessionRegistry.Record(
            provider: provider,
            sessionID: storedSessionID,
            updatedAt: 100,
            json: try JSONSerialization.data(withJSONObject: [
                "sessionId": projectedSessionID,
                "workspaceId": projectedWorkspaceID,
                "surfaceId": projectedSurfaceID,
                "startedAt": 100.0,
                "updatedAt": 100.0,
            ], options: [.sortedKeys])
        )
        let slotJSON = try JSONSerialization.data(withJSONObject: [
            "sessionId": projectedSessionID,
            "updatedAt": 100.0,
        ], options: [.sortedKeys])
        try fixture.registry.apply(
            provider: provider,
            records: [record],
            activeSlots: [
                .init(
                    provider: provider,
                    scope: .workspace,
                    scopeID: storedWorkspaceID,
                    sessionID: storedSessionID,
                    updatedAt: 100,
                    json: slotJSON
                ),
                .init(
                    provider: provider,
                    scope: .surface,
                    scopeID: storedSurfaceID,
                    sessionID: storedSessionID,
                    updatedAt: 100,
                    json: slotJSON
                ),
            ]
        )

        let complete = try fixture.registry.snapshot(provider: provider)
        #expect(complete.records.count == 1)
        #expect(complete.activeSlots.count == 2)
        let bounded = try fixture.registry.hookBoundedRecentSnapshot(
            provider: provider,
            maximumRecords: 1
        )
        #expect(bounded.totalRecordCount == 1)
        #expect(bounded.snapshot.records.map(\.sessionID) == [storedSessionID])
        #expect(Set(bounded.snapshot.activeSlots.map(\.scopeID)) == [
            storedWorkspaceID, storedSurfaceID,
        ])
    }

    @Test("active slot writes align canonically equivalent owner identities")
    func boundedListJoinsCanonicalUnicodeSlotOwner() throws {
        let fixture = try makeFixture()
        let provider = "unicode-slot-owner"
        let recordSessionID = "session-\u{00E9}"
        let slotSessionID = "session-e\u{0301}"
        #expect(recordSessionID == slotSessionID)
        let record = try record(
            provider: provider,
            sessionID: recordSessionID,
            workspaceID: "workspace",
            surfaceID: "surface",
            updatedAt: 100
        )
        let slotJSON = try JSONSerialization.data(withJSONObject: [
            "sessionId": slotSessionID,
            "updatedAt": 100.0,
        ], options: [.sortedKeys])
        try fixture.registry.apply(
            provider: provider,
            records: [record],
            activeSlots: [.init(
                provider: provider,
                scope: .workspace,
                scopeID: "workspace",
                sessionID: slotSessionID,
                updatedAt: 100,
                json: slotJSON
            )]
        )

        let storedSlot = try #require(
            fixture.registry.snapshot(provider: provider).activeSlots.first
        )
        #expect(storedSlot.sessionID.utf8.elementsEqual(recordSessionID.utf8))

        let bounded = try fixture.registry.hookBoundedRecentSnapshot(
            provider: provider,
            maximumRecords: 1
        )

        #expect(bounded.snapshot.records.map(\.sessionID) == [recordSessionID])
        #expect(bounded.snapshot.activeSlots.count == 1)
        #expect(bounded.snapshot.activeSlots.first?.sessionID == recordSessionID)
    }

    @Test("bounded legacy import preserves canonical storage failures")
    func boundedLegacyImportPreservesCanonicalStorageFailure() throws {
        let fixture = try makeFixture()
        let provider = "legacy-storage-failure"
        _ = try fixture.registry.snapshot(provider: provider)
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                "legacy-session": [
                    "sessionId": "legacy-session",
                    "workspaceId": "workspace",
                    "surfaceId": "surface",
                    "updatedAt": 100.0,
                ],
            ],
            "activeSessionsByWorkspace": [:],
            "activeSessionsBySurface": [:],
        ], options: [.sortedKeys]).write(to: fixture.legacyURL, options: .atomic)
        try executeRegistrySQL(
            at: fixture.directory.appendingPathComponent(CmuxAgentSessionRegistry.filename),
            sql: """
            CREATE TRIGGER reject_legacy_session_insert
            BEFORE INSERT ON agent_sessions BEGIN
                SELECT RAISE(ABORT, 'forced canonical storage failure');
            END;
            """
        )

        var caught: (any Error)?
        do {
            _ = try fixture.registry.boundedRecentSnapshotsImportingLegacy(
                sources: [.init(provider: provider, url: fixture.legacyURL)],
                maximumRecordsPerProvider: 1
            )
        } catch {
            caught = error
        }

        #expect(caught != nil)
        #expect(!(caught is CmuxAgentSessionRegistry.HookLegacySourceImportError))
    }

    @Test("bounded list rejects a corrupt authoritative row outside top K")
    func boundedListValidatesOmittedRows() throws {
        let fixture = try makeFixture()
        let provider = "corrupt-omitted"
        var corrupt = try record(
            provider: provider,
            sessionID: "embedded-identity",
            workspaceID: "old-workspace",
            surfaceID: "old-surface",
            updatedAt: 1
        )
        corrupt.sessionID = "canonical-identity"
        let valid = try record(
            provider: provider,
            sessionID: "newest-valid",
            workspaceID: "new-workspace",
            surfaceID: "new-surface",
            updatedAt: 2
        )
        try fixture.registry.apply(provider: provider, records: [corrupt, valid])

        var failure: CmuxAgentSessionRegistry.HookListProjectionValidationError?
        do {
            _ = try fixture.registry.hookBoundedRecentSnapshot(
                provider: provider,
                maximumRecords: 1
            )
        } catch let error as CmuxAgentSessionRegistry.HookListProjectionValidationError {
            failure = error
        }

        let error = try #require(failure)
        #expect(error.provider == provider)
    }

    @Test("twenty thousand list payloads receive streaming full validation")
    func boundedListFullValidationStreamsEveryRecord() throws {
        let fixture = try makeFixture()
        let provider = "stream-validation"
        let records = try (0..<20_000).map { index in
            try record(
                provider: provider,
                sessionID: String(format: "session-%05d", index),
                workspaceID: "workspace-\(index % 100)",
                surfaceID: "surface-\(index)",
                updatedAt: TimeInterval(index)
            )
        }
        try fixture.registry.apply(provider: provider, records: records)

        let decoder = JSONDecoder()
        var validatedRecords = 0
        var validatedSlots = 0
        let startedAt = Date().timeIntervalSinceReferenceDate
        let snapshots = try fixture.registry.boundedRecentSnapshotsImportingLegacy(
            sources: [.init(
                provider: provider,
                url: fixture.directory.appendingPathComponent("stream-validation.json")
            )],
            maximumRecordsPerProvider: 100,
            validateRecord: { validatedProvider, record in
                #expect(validatedProvider == provider)
                let decoded = try decoder.decode(
                    StreamingListRecord.self,
                    from: record.json
                )
                #expect(decoded.sessionId == record.sessionID)
                validatedRecords += 1
            },
            validateActiveSlot: { validatedProvider, slot in
                #expect(validatedProvider == provider)
                let decoded = try decoder.decode(
                    StreamingListSlot.self,
                    from: slot.json
                )
                #expect(decoded.sessionId == slot.sessionID)
                validatedSlots += 1
            }
        )
        let elapsed = Date().timeIntervalSinceReferenceDate - startedAt
        print("bounded list full-decode 20000-row elapsed: \(elapsed) seconds")

        #expect(validatedRecords == 20_000)
        #expect(validatedSlots == 0)
        #expect(snapshots[provider]?.totalRecordCount == 20_000)
        #expect(snapshots[provider]?.snapshot.records.count == 100)
    }

    @Test("hibernation projection reads only active owners and exact detected sessions")
    func hibernationProjectionIsIndependentOfProviderHistory() throws {
        let fixture = try makeFixture()
        let provider = "hibernation-projection"
        let records = try (0..<20_000).map { index in
            try record(
                provider: provider,
                sessionID: String(format: "session-%05d", index),
                workspaceID: "workspace-\(index)",
                surfaceID: "surface-\(index)",
                updatedAt: TimeInterval(index)
            )
        }
        try fixture.registry.apply(
            provider: provider,
            records: records,
            activeSlots: try slots(
                provider: provider,
                sessionID: "session-10000",
                workspaceID: "workspace-10000",
                surfaceID: "surface-10000",
                updatedAt: 10_000
            )
        )

        let startedAt = Date().timeIntervalSinceReferenceDate
        let snapshot = try fixture.registry.hookHibernationSnapshot(
            provider: provider,
            panelContexts: [.init(
                workspaceID: "workspace-10000",
                surfaceID: "surface-10000"
            )],
            exactSessionIDs: ["session-15000"],
            maximumRecords: 3,
            maximumBytes: Int64(CmuxAgentSessionRegistry.maximumHookProviderBytes)
        )
        let elapsed = Date().timeIntervalSinceReferenceDate - startedAt
        print("hibernation projection 20000-row elapsed: \(elapsed) seconds")

        #expect(Set(snapshot.records.map(\.sessionID)) == ["session-10000", "session-15000"])
        #expect(snapshot.activeSlots.count == 1)
        #expect(elapsed < 0.5)
    }

    @Test("hibernation projection fails closed at row and byte limits")
    func hibernationProjectionEnforcesMaterializationLimits() throws {
        let fixture = try makeFixture()
        let provider = "hibernation-limits"
        let first = try record(
            provider: provider,
            sessionID: "first",
            workspaceID: "workspace-first",
            surfaceID: "surface-first",
            updatedAt: 1
        )
        let second = try record(
            provider: provider,
            sessionID: "second",
            workspaceID: "workspace-second",
            surfaceID: "surface-second",
            updatedAt: 2
        )
        try fixture.registry.apply(provider: provider, records: [first, second])

        #expect(throws: CmuxAgentSessionRegistry.HookSnapshotLimitError.self) {
            try fixture.registry.hookHibernationSnapshot(
                provider: provider,
                panelContexts: [],
                exactSessionIDs: ["first", "second"],
                maximumRecords: 1,
                maximumBytes: .max
            )
        }
        #expect(throws: CmuxAgentSessionRegistry.HookSnapshotLimitError.self) {
            try fixture.registry.hookHibernationSnapshot(
                provider: provider,
                panelContexts: [],
                exactSessionIDs: ["first"],
                maximumRecords: 1,
                maximumBytes: Int64(first.json.count - 1)
            )
        }
    }

    @Test("batched hibernation ignores irrelevant providers and isolates malformed peers")
    func batchedHibernationSelectsRelevantProviders() throws {
        let fixture = try makeFixture()
        let provider = "provider-255"
        let sessionID = "active-owner"
        let activeRecord = try record(
            provider: provider,
            sessionID: sessionID,
            workspaceID: "workspace",
            surfaceID: "surface",
            updatedAt: 1
        )
        try fixture.registry.apply(
            provider: provider,
            records: [activeRecord],
            activeSlots: try slots(
                provider: provider,
                sessionID: sessionID,
                workspaceID: "workspace",
                surfaceID: "surface",
                updatedAt: 1
            )
        )
        try fixture.registry.apply(provider: "malformed", records: [.init(
            provider: "malformed",
            sessionID: "broken",
            updatedAt: 2,
            json: Data("{}".utf8)
        )])
        let configuredProviders = Set((0..<256).map { "provider-\($0)" })
            .union(["malformed"])

        let result = try fixture.registry.hookHibernationSnapshots(
            providers: configuredProviders,
            panelContexts: [.init(workspaceID: "workspace", surfaceID: "surface")],
            exactSessionIDsByProvider: ["malformed": ["broken"]],
            maximumProviders: 64,
            maximumRecords: 64,
            maximumBytes: 1_024 * 1_024
        )

        #expect(result.snapshots[provider]?.records.map(\.sessionID) == [sessionID])
        #expect(result.snapshots[provider]?.activeSlots.map(\.sessionID) == [sessionID])
        #expect(result.failedProviders == ["malformed"])
        #expect(result.snapshots["malformed"]?.records.isEmpty == true)
        #expect(result.snapshots.count == 2)
    }

    @Test("legacy reads reject oversized files before allocating their payload")
    func legacyReadHasDescriptorBound() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = FileManager.default.createFile(atPath: fixture.legacyURL.path, contents: Data())
        let handle = try FileHandle(forWritingTo: fixture.legacyURL)
        try handle.truncate(atOffset: UInt64(64 * 1_024 * 1_024 + 1))
        try handle.close()

        var failure: CmuxAgentSessionRegistry.HookLegacySourceSizeError?
        do {
            _ = try fixture.registry.readHookLegacySourceData(at: fixture.legacyURL)
        } catch let error as CmuxAgentSessionRegistry.HookLegacySourceSizeError {
            failure = error
        }
        let error = try #require(failure)
        #expect(error.observedBytes == 64 * 1_024 * 1_024 + 1)
        #expect(error.maximumBytes == 64 * 1_024 * 1_024)
    }

    @Test("legacy reads reject non-regular files before reading")
    func legacyReadRejectsNonRegularFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.createDirectory(at: fixture.legacyURL, withIntermediateDirectories: false)

        var failure: POSIXError?
        do {
            _ = try fixture.registry.readHookLegacySourceData(at: fixture.legacyURL)
        } catch let error as POSIXError {
            failure = error
        }
        #expect(try #require(failure).code == .EFTYPE)
    }

    @Test("thirty-two disjoint hook mutations do not lose rows")
    func disjointConcurrentMutationsDoNotLoseRows() async throws {
        let fixture = try makeFixture()
        _ = try fixture.registry.hookProjectionStatus(provider: "claude")
        let now = Date().timeIntervalSince1970
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let sessionID = "disjoint-\(index)"
                    _ = try fixture.registry.mutateHookSession(
                        provider: "claude",
                        sessionID: sessionID
                    ) { snapshot in
                        snapshot.records = [try self.record(
                            provider: "claude",
                            sessionID: sessionID,
                            workspaceID: "workspace-\(index)",
                            surfaceID: "surface-\(index)",
                            updatedAt: now + TimeInterval(index)
                        )]
                    }
                }
            }
            try await group.waitForAll()
        }
        let snapshot = try fixture.registry.snapshot(provider: "claude")
        #expect(Set(snapshot.records.map(\.sessionID)) == Set((0..<32).map { "disjoint-\($0)" }))
    }

    @Test("independent first-use writers migrate a fresh registry without dropping hooks")
    func concurrentColdStartMigrationDoesNotDropHooks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-cold-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registryURL = directory.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let now = Date().timeIntervalSince1970

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let registry = CmuxAgentSessionRegistry(
                        url: registryURL,
                        busyTimeoutMilliseconds: 250
                    )
                    let sessionID = "cold-\(index)"
                    _ = try registry.mutateHookSession(
                        provider: "codex",
                        sessionID: sessionID,
                        now: now
                    ) { snapshot in
                        snapshot.records = [try self.record(
                            provider: "codex",
                            sessionID: sessionID,
                            workspaceID: "workspace-\(index)",
                            surfaceID: "surface-\(index)",
                            updatedAt: now + TimeInterval(index)
                        )]
                    }
                }
            }
            try await group.waitForAll()
        }

        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let ids = Set(try registry.snapshot(provider: "codex").records.map(\.sessionID))
        #expect(ids == Set((0..<32).map { "cold-\($0)" }))
        #expect(try registry.hookProjectionStatus(provider: "codex").revision >= 32)
    }

    @Test("thirty-two same-session hook mutations replay without lost increments")
    func sameSessionConcurrentMutationsDoNotLoseUpdates() async throws {
        let fixture = try makeFixture()
        let initial = try record(
            provider: "opencode",
            sessionID: "shared",
            workspaceID: "workspace",
            surfaceID: "surface",
            updatedAt: 1,
            extra: ["counter": 0]
        )
        try fixture.registry.apply(provider: "opencode", records: [initial])
        _ = try fixture.registry.hookProjectionStatus(provider: "opencode")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    _ = try fixture.registry.mutateHookSession(
                        provider: "opencode",
                        sessionID: "shared",
                        now: 100
                    ) { snapshot in
                        var stored = try #require(snapshot.records.first)
                        var object = try #require(
                            JSONSerialization.jsonObject(with: stored.json) as? [String: Any]
                        )
                        let counter = object["counter"] as? Int ?? 0
                        object["counter"] = counter + 1
                        stored.updatedAt = TimeInterval(counter + 2)
                        object["updatedAt"] = stored.updatedAt
                        stored.json = try JSONSerialization.data(
                            withJSONObject: object,
                            options: [.sortedKeys]
                        )
                        snapshot.records = [stored]
                    }
                }
            }
            try await group.waitForAll()
        }

        let stored = try #require(
            try fixture.registry.hookRecord(provider: "opencode", sessionID: "shared")
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: stored.json) as? [String: Any]
        )
        #expect(object["counter"] as? Int == 32)
    }

    @Test("canonical projection marks only its captured revision and preserves unknown fields")
    func projectionRevisionIsExactAndLossless() throws {
        let fixture = try makeFixture()
        _ = try fixture.registry.hookProjectionStatus(provider: "pi")
        let stored = try record(
            provider: "pi",
            sessionID: "session",
            workspaceID: "workspace",
            surfaceID: "surface",
            updatedAt: 1,
            extra: ["futureField": ["nested": true]]
        )
        try fixture.registry.apply(
            provider: "pi",
            records: [stored],
            activeSlots: try slots(
                provider: "pi",
                sessionID: "session",
                workspaceID: "workspace",
                surfaceID: "surface",
                updatedAt: 1
            )
        )
        let existing = try JSONSerialization.data(withJSONObject: ["futureTopLevel": "kept"])
        let projection = try fixture.registry.hookLegacyProjection(
            provider: "pi",
            preservingTopLevelJSON: existing
        )
        try projection.json.write(to: fixture.legacyURL, options: .atomic)
        let stamp = try #require(CmuxAgentSessionRegistry.LegacyStamp.read(path: fixture.legacyURL.path))
        try fixture.registry.markHookLegacyProjection(
            provider: "pi",
            revision: projection.revision,
            stamp: stamp
        )

        let status = try fixture.registry.hookProjectionStatus(provider: "pi")
        #expect(status.revision == projection.revision)
        #expect(status.projectedRevision == projection.revision)
        let root = try #require(
            JSONSerialization.jsonObject(with: projection.json) as? [String: Any]
        )
        #expect(root["futureTopLevel"] as? String == "kept")
        let sessions = try #require(root["sessions"] as? [String: Any])
        let session = try #require(sessions["session"] as? [String: Any])
        let future = try #require(session["futureField"] as? [String: Any])
        #expect(future["nested"] as? Bool == true)
    }

    @Test("compatibility projection keeps active owners and the newest 256 inactive records")
    func compatibilityProjectionIsBoundedAndDeterministic() throws {
        let fixture = try makeFixture()
        _ = try fixture.registry.hookProjectionStatus(provider: "claude")
        let records = try (0..<300).map { index in
            try record(
                provider: "claude",
                sessionID: String(format: "session-%03d", index),
                workspaceID: "workspace-\(index)",
                surfaceID: "surface-\(index)",
                updatedAt: TimeInterval(index),
                extra: index == 0 || index == 299
                    ? ["futureField": "kept-\(index)"]
                    : [:]
            )
        }
        try fixture.registry.apply(
            provider: "claude",
            records: records,
            activeSlots: try slots(
                provider: "claude",
                sessionID: "session-000",
                workspaceID: "workspace-0",
                surfaceID: "surface-0",
                updatedAt: 0
            )
        )

        let canonicalStatus = try fixture.registry.hookProjectionStatus(provider: "claude")
        let projection = try fixture.registry.hookLegacyProjection(provider: "claude")
        let root = try #require(
            JSONSerialization.jsonObject(with: projection.json) as? [String: Any]
        )
        let sessions = try #require(root["sessions"] as? [String: Any])
        #expect(sessions.count == 257)
        #expect(sessions["session-000"] != nil)
        #expect(sessions["session-043"] == nil)
        #expect(sessions["session-044"] != nil)
        #expect(sessions["session-299"] != nil)
        #expect(
            (sessions["session-000"] as? [String: Any])?["futureField"] as? String
                == "kept-0"
        )
        #expect(
            (sessions["session-299"] as? [String: Any])?["futureField"] as? String
                == "kept-299"
        )
        #expect(projection.revision == canonicalStatus.revision)

        try projection.json.write(to: fixture.legacyURL, options: .atomic)
        let stamp = try #require(
            CmuxAgentSessionRegistry.LegacyStamp.read(path: fixture.legacyURL.path)
        )
        try fixture.registry.markHookLegacyProjection(
            provider: "claude",
            revision: projection.revision,
            stamp: stamp
        )
        let projectedStatus = try fixture.registry.hookProjectionStatus(provider: "claude")
        #expect(projectedStatus.revision == projection.revision)
        #expect(projectedStatus.projectedRevision == projection.revision)

        let canonical = try fixture.registry.snapshot(provider: "claude")
        #expect(canonical.records.count == 300)
        #expect(canonical.records.contains { $0.sessionID == "session-043" })
        #expect(
            try fixture.registry.hookRecord(provider: "claude", sessionID: "session-043")
                != nil
        )
        let boundedCanonical = try fixture.registry.hookBoundedSnapshot(
            provider: "claude",
            maximumRecords: 300
        )
        #expect(boundedCanonical.records.count == 300)
        #expect(boundedCanonical.records.contains { $0.sessionID == "session-043" })

        var countFailure: CmuxAgentSessionRegistry.HookSnapshotLimitError?
        do {
            _ = try fixture.registry.hookBoundedSnapshot(
                provider: "claude",
                maximumRecords: 299
            )
        } catch let error as CmuxAgentSessionRegistry.HookSnapshotLimitError {
            countFailure = error
        }
        let countError = try #require(countFailure)
        #expect(countError.scope == .records)
        #expect(countError.observed == 300)
        #expect(countError.maximum == 299)
    }

    @Test("compatibility projection rejects active-owner overflow before copying records")
    func compatibilityProjectionPreflightsActiveOwnerCount() throws {
        let fixture = try makeFixture()
        let provider = "projection-owner-overflow"
        let count = CmuxAgentSessionRegistry.maximumHookLegacyProjectionRecords + 1
        var records: [CmuxAgentSessionRegistry.Record] = []
        var activeSlots: [CmuxAgentSessionRegistry.ActiveSlot] = []
        records.reserveCapacity(count)
        activeSlots.reserveCapacity(count)
        for index in 0..<count {
            let sessionID = String(format: "session-%05d", index)
            let recordJSON = try JSONSerialization.data(withJSONObject: [
                "sessionId": sessionID,
                "updatedAt": TimeInterval(index),
            ], options: [.sortedKeys])
            records.append(.init(
                provider: provider,
                sessionID: sessionID,
                updatedAt: TimeInterval(index),
                json: recordJSON
            ))
            activeSlots.append(.init(
                provider: provider,
                scope: .surface,
                scopeID: "surface-\(index)",
                sessionID: sessionID,
                updatedAt: TimeInterval(index),
                json: recordJSON
            ))
        }
        try fixture.registry.apply(
            provider: provider,
            records: records,
            activeSlots: activeSlots
        )

        var failure: CmuxAgentSessionRegistry.HookSnapshotLimitError?
        do {
            _ = try fixture.registry.hookLegacyProjection(provider: provider)
        } catch let error as CmuxAgentSessionRegistry.HookSnapshotLimitError {
            failure = error
        }
        let error = try #require(failure)
        #expect(error.scope == .records)
        #expect(error.observed == Int64(count))
        #expect(error.maximum == Int64(CmuxAgentSessionRegistry.maximumHookLegacyProjectionRecords))
    }

    @Test("an older writer cannot delete canonical history omitted by a bounded projection")
    func boundedProjectionLegacyRoundTripPreservesCanonicalHistory() throws {
        let fixture = try makeFixture()
        _ = try fixture.registry.hookProjectionStatus(provider: "codex")
        let records = try (0..<300).map { index in
            try record(
                provider: "codex",
                sessionID: String(format: "session-%03d", index),
                workspaceID: "workspace-\(index)",
                surfaceID: "surface-\(index)",
                updatedAt: TimeInterval(index),
                extra: index == 1 ? ["omittedHistoryField": "survives"] : [:]
            )
        }
        try fixture.registry.importLegacy(
            provider: "codex",
            stamp: .init(path: "initial", size: 1, modifiedAt: 1),
            records: records,
            activeSlots: try slots(
                provider: "codex",
                sessionID: "session-000",
                workspaceID: "workspace-0",
                surfaceID: "surface-0",
                updatedAt: 0
            )
        )
        let revision = try fixture.registry.hookProjectionStatus(provider: "codex").revision
        try fixture.registry.projectHookLegacyStore(
            provider: "codex",
            to: fixture.legacyURL,
            including: revision
        )

        let data = try Data(contentsOf: fixture.legacyURL)
        var root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var sessions = try #require(root["sessions"] as? [String: Any])
        sessions["session-300"] = [
            "sessionId": "session-300",
            "workspaceId": "workspace-300",
            "surfaceId": "surface-300",
            "updatedAt": 300.0,
            "runtimeStatus": "running",
        ]
        root["sessions"] = sessions
        root["activeSessionsByWorkspace"] = [:]
        root["activeSessionsBySurface"] = [:]
        let oldWriterJSON = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try oldWriterJSON.write(to: fixture.legacyURL, options: .atomic)

        let refresh = try fixture.registry.refreshLegacySources([
            .init(provider: "codex", url: fixture.legacyURL),
        ])
        #expect(refresh.refreshedProviders == ["codex"])
        let canonical = try fixture.registry.snapshot(provider: "codex")
        #expect(canonical.records.count == 301)
        #expect(canonical.records.contains { $0.sessionID == "session-300" })
        let omitted = try #require(
            canonical.records.first { $0.sessionID == "session-001" }
        )
        let omittedObject = try #require(
            JSONSerialization.jsonObject(with: omitted.json) as? [String: Any]
        )
        #expect(omittedObject["omittedHistoryField"] as? String == "survives")
        #expect(canonical.activeSlots.isEmpty)
    }

    @Test("an intervening atomic legacy replacement cannot be marked as canonical")
    func interveningLegacyReplacementIsRejected() throws {
        let fixture = try makeFixture()
        _ = try fixture.registry.hookProjectionStatus(provider: "claude")
        try fixture.registry.apply(
            provider: "claude",
            records: [try record(
                provider: "claude",
                sessionID: "canonical",
                workspaceID: "workspace",
                surfaceID: "surface",
                updatedAt: 1
            )]
        )
        let revision = try fixture.registry.hookProjectionStatus(provider: "claude").revision
        let interveningJSON = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                "old-writer": [
                    "sessionId": "old-writer",
                    "updatedAt": 2.0,
                ],
            ],
            "activeSessionsByWorkspace": [:],
            "activeSessionsBySurface": [:],
        ], options: [.prettyPrinted, .sortedKeys])

        var rejected = false
        do {
            try fixture.registry.projectHookLegacyStore(
                provider: "claude",
                to: fixture.legacyURL,
                including: revision,
                afterPublishing: {
                    try interveningJSON.write(to: fixture.legacyURL, options: .atomic)
                }
            )
        } catch {
            rejected = true
        }
        #expect(rejected)
        #expect(
            try fixture.registry.hookProjectionStatus(provider: "claude").projectedRevision
                < revision
        )

        try fixture.registry.projectHookLegacyStore(
            provider: "claude",
            to: fixture.legacyURL,
            including: revision
        )
        let finalData = try Data(contentsOf: fixture.legacyURL)
        let finalRoot = try #require(
            JSONSerialization.jsonObject(with: finalData) as? [String: Any]
        )
        let sessions = try #require(finalRoot["sessions"] as? [String: Any])
        #expect(sessions["canonical"] != nil)
        #expect(sessions["old-writer"] == nil)
        #expect(
            try fixture.registry.hookProjectionStatus(provider: "claude").projectedRevision
                >= revision
        )
    }

    @Test("a held compatibility lock cannot block a hook projection")
    func compatibilityLockContentionFailsImmediatelyAndRecovers() throws {
        let fixture = try makeFixture()
        _ = try fixture.registry.hookProjectionStatus(provider: "codex")
        try fixture.registry.apply(
            provider: "codex",
            records: [try record(
                provider: "codex",
                sessionID: "session",
                workspaceID: "workspace",
                surfaceID: "surface",
                updatedAt: 1
            )]
        )
        let revision = try fixture.registry.hookProjectionStatus(provider: "codex").revision
        let descriptor = open(
            fixture.legacyURL.path + ".lock",
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)

        var contentionCode: POSIXErrorCode?
        do {
            try fixture.registry.projectHookLegacyStore(
                provider: "codex",
                to: fixture.legacyURL,
                including: revision
            )
        } catch let error as POSIXError {
            contentionCode = error.code
        }
        #expect(contentionCode == .EWOULDBLOCK || contentionCode == .EAGAIN)
        #expect(
            try fixture.registry.hookProjectionStatus(provider: "codex").projectedRevision
                < revision
        )
        #expect(
            try fixture.registry.hookRecord(provider: "codex", sessionID: "session") != nil
        )

        #expect(flock(descriptor, LOCK_UN) == 0)
        // This second call represents the next hook/app lifecycle event. It
        // observes the committed canonical row and converges compatibility.
        try fixture.registry.projectHookLegacyStore(
            provider: "codex",
            to: fixture.legacyURL,
            including: revision
        )
        #expect(
            try fixture.registry.hookProjectionStatus(provider: "codex").projectedRevision
                >= revision
        )
    }

    @Test("an absent compatibility file projects a versioned store that imports losslessly")
    func absentCompatibilityFileProjectionRoundTrips() throws {
        let source = try makeFixture()
        _ = try source.registry.hookProjectionStatus(provider: "cursor")
        let stored = try record(
            provider: "cursor",
            sessionID: "fresh",
            workspaceID: "workspace",
            surfaceID: "surface",
            updatedAt: 10,
            extra: ["futureField": "kept"]
        )
        try source.registry.apply(provider: "cursor", records: [stored])
        let projection = try source.registry.hookLegacyProjection(provider: "cursor")
        let root = try #require(
            JSONSerialization.jsonObject(with: projection.json) as? [String: Any]
        )
        #expect(root["version"] as? Int == 2)

        let destination = try makeFixture()
        try destination.registry.importLegacyStoreJSON(
            provider: "cursor",
            stamp: .init(path: "memory", size: Int64(projection.json.count), modifiedAt: 1),
            json: projection.json
        )
        let roundTripped = try #require(
            try destination.registry.hookRecord(provider: "cursor", sessionID: "fresh")
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: roundTripped.json) as? [String: Any]
        )
        #expect(object["futureField"] as? String == "kept")
    }

    @Test("maintenance is deterministic and preserves active and future-generation rows")
    func deterministicMaintenancePreservesAuthorities() throws {
        let fixture = try makeFixture()
        _ = try fixture.registry.hookProjectionStatus(provider: "gemini")
        var records = try (0..<10_002).map { index in
            try record(
                provider: "gemini",
                sessionID: String(format: "session-%05d", index),
                workspaceID: "workspace-\(index)",
                surfaceID: "surface-\(index)",
                updatedAt: 100
            )
        }
        records[1].writerGeneration = CmuxAgentSessionRegistry.currentWriterGeneration + 1
        let active = try slots(
            provider: "gemini",
            sessionID: "session-00000",
            workspaceID: "workspace-0",
            surfaceID: "surface-0",
            updatedAt: 100
        )
        let dangling = try slots(
            provider: "gemini",
            sessionID: "missing",
            workspaceID: "dangling-workspace",
            surfaceID: "dangling-surface",
            updatedAt: 100
        )
        try fixture.registry.apply(
            provider: "gemini",
            records: records,
            activeSlots: active + dangling
        )

        _ = try fixture.registry.mutateHookSession(
            provider: "gemini",
            sessionID: "session-10001",
            now: 100
        ) { _ in }
        let snapshot = try fixture.registry.snapshot(provider: "gemini")
        let ids = Set(snapshot.records.map(\.sessionID))
        #expect(ids.count == 10_000)
        #expect(ids.contains("session-00000"))
        #expect(ids.contains("session-00001"))
        #expect(!ids.contains("session-00002"))
        #expect(!ids.contains("session-00003"))
        #expect(!snapshot.activeSlots.contains { $0.sessionID == "missing" })
    }

    @Test("maintenance expires only inactive current-generation rows older than seven days")
    func maintenanceExpiresOldInactiveRows() throws {
        let fixture = try makeFixture()
        _ = try fixture.registry.hookProjectionStatus(provider: "amp")
        let now = 8 * 24 * 60 * 60.0
        var future = try record(
            provider: "amp",
            sessionID: "future",
            workspaceID: "workspace-future",
            surfaceID: "surface-future",
            updatedAt: 0
        )
        future.writerGeneration = CmuxAgentSessionRegistry.currentWriterGeneration + 1
        try fixture.registry.apply(
            provider: "amp",
            records: [
                try record(
                    provider: "amp",
                    sessionID: "expired",
                    workspaceID: "workspace-expired",
                    surfaceID: "surface-expired",
                    updatedAt: 0
                ),
                try record(
                    provider: "amp",
                    sessionID: "active-old",
                    workspaceID: "workspace-active",
                    surfaceID: "surface-active",
                    updatedAt: 0
                ),
                try record(
                    provider: "amp",
                    sessionID: "recent",
                    workspaceID: "workspace-recent",
                    surfaceID: "surface-recent",
                    updatedAt: now
                ),
                future,
            ],
            activeSlots: try slots(
                provider: "amp",
                sessionID: "active-old",
                workspaceID: "workspace-active",
                surfaceID: "surface-active",
                updatedAt: 0
            )
        )

        _ = try fixture.registry.mutateHookSession(
            provider: "amp",
            sessionID: "recent",
            now: now
        ) { _ in }
        let ids = Set(try fixture.registry.snapshot(provider: "amp").records.map(\.sessionID))
        #expect(!ids.contains("expired"))
        #expect(ids.contains("active-old"))
        #expect(ids.contains("recent"))
        #expect(ids.contains("future"))
    }

    @Test("a near-cap insert prunes the oldest inactive history")
    func nearCapInsertPrunesInactiveHistory() throws {
        let fixture = try makeFixture()
        let provider = "near-cap"
        let payloadBytes = CmuxAgentSessionRegistry.maximumHookRecordBytes - 2_048
        let records = try (0..<16).map { index in
            try largeRecord(
                provider: provider,
                sessionID: String(format: "old-%02d", index),
                updatedAt: TimeInterval(index),
                payloadBytes: payloadBytes
            )
        }
        try fixture.registry.apply(provider: provider, records: records)
        let before = try fixture.registry.hookStorageMetrics(provider: provider)
        #expect(before.recordCount == 16)
        #expect(before.totalBytes < Int64(CmuxAgentSessionRegistry.maximumHookProviderBytes))

        let inserted = try largeRecord(
            provider: provider,
            sessionID: "new",
            updatedAt: 100,
            payloadBytes: 128 * 1_024
        )
        try fixture.registry.apply(provider: provider, records: [inserted])

        let after = try fixture.registry.hookStorageMetrics(provider: provider)
        #expect(after.totalBytes <= Int64(CmuxAgentSessionRegistry.maximumHookProviderBytes))
        let snapshot = try fixture.registry.hookBoundedSnapshot(provider: provider)
        #expect(snapshot.records.contains { $0.sessionID == "new" })
        #expect(!snapshot.records.contains { $0.sessionID == "old-00" })
    }

    @Test("an oversized input batch is rejected before SQLite is opened")
    func oversizedBatchIsRejectedBeforeDatabaseWrite() throws {
        let fixture = try makeFixture()
        let provider = "oversized-batch"
        let payloadBytes = CmuxAgentSessionRegistry.maximumHookRecordBytes - 2_048
        let records = try (0..<17).map { index in
            try largeRecord(
                provider: provider,
                sessionID: "batch-\(index)",
                updatedAt: TimeInterval(index),
                payloadBytes: payloadBytes
            )
        }

        var failure: CmuxAgentSessionRegistry.HookStorageLimitError?
        do {
            try fixture.registry.apply(provider: provider, records: records)
        } catch let error as CmuxAgentSessionRegistry.HookStorageLimitError {
            failure = error
        }
        let error = try #require(failure)
        #expect(error.scope == .provider)
        #expect(error.observedBytes > error.maximumBytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.registry.url.path))
    }

    @Test("a growing mutation rolls back when only protected or active rows remain")
    func providerCapRejectsUnprunableGrowingMutation() throws {
        let fixture = try makeFixture()
        let provider = "active-cap"
        let payloadBytes = CmuxAgentSessionRegistry.maximumHookRecordBytes - 2_048
        var records: [CmuxAgentSessionRegistry.Record] = []
        var activeSlots: [CmuxAgentSessionRegistry.ActiveSlot] = []
        for index in 0..<16 {
            let sessionID = String(format: "active-%02d", index)
            records.append(try largeRecord(
                provider: provider,
                sessionID: sessionID,
                updatedAt: TimeInterval(index),
                payloadBytes: payloadBytes
            ))
            activeSlots.append(contentsOf: try slots(
                provider: provider,
                sessionID: sessionID,
                workspaceID: "workspace-\(sessionID)",
                surfaceID: "surface-\(sessionID)",
                updatedAt: TimeInterval(index)
            ))
        }
        try fixture.registry.apply(
            provider: provider,
            records: records,
            activeSlots: activeSlots
        )
        let before = try fixture.registry.hookStorageMetrics(provider: provider)

        var limitFailure: CmuxAgentSessionRegistry.HookStorageLimitError?
        do {
            _ = try fixture.registry.mutateHookSession(
                provider: provider,
                sessionID: "protected-new",
                now: 200
            ) { snapshot in
                snapshot.records = [try largeRecord(
                    provider: provider,
                    sessionID: "protected-new",
                    updatedAt: 200,
                    payloadBytes: payloadBytes
                )]
            }
        } catch let error as CmuxAgentSessionRegistry.HookStorageLimitError {
            limitFailure = error
        }
        let error = try #require(limitFailure)
        #expect(error.scope == .provider)
        #expect(
            try fixture.registry.hookRecord(provider: provider, sessionID: "protected-new")
                == nil
        )
        #expect(try fixture.registry.hookStorageMetrics(provider: provider) == before)
    }

    @Test("an existing oversized v5 provider accepts a non-growing update")
    func oversizedProviderIsNotWedgedForNonGrowingUpdate() throws {
        let fixture = try makeFixture()
        let provider = "oversized-v5"
        _ = try fixture.registry.hookProjectionStatus(provider: provider)
        let payloadBytes = CmuxAgentSessionRegistry.maximumHookRecordBytes - 2_048
        var records: [CmuxAgentSessionRegistry.Record] = []
        for index in 0..<17 {
            records.append(try largeRecord(
                provider: provider,
                sessionID: String(format: "active-%02d", index),
                updatedAt: TimeInterval(index),
                payloadBytes: payloadBytes
            ))
        }
        try insertRawRecords(
            records,
            provider: provider,
            registryURL: fixture.registry.url,
            createActiveSlots: true
        )
        let before = try fixture.registry.hookStorageMetrics(provider: provider)
        #expect(before.totalBytes > Int64(CmuxAgentSessionRegistry.maximumHookProviderBytes))

        let patched = try fixture.registry.patchRecord(
            provider: provider,
            sessionID: "active-00",
            updatedAt: 1_000
        ) { _ in }
        #expect(patched)
        let after = try fixture.registry.hookStorageMetrics(provider: provider)
        #expect(after.totalBytes == before.totalBytes)
        #expect(
            try fixture.registry.hookRecord(provider: provider, sessionID: "active-00")?.updatedAt
                == 1_000
        )
    }

    @Test("v4 migration prunes oversized inactive history before returning")
    func migrationRecoversOversizedProvider() throws {
        let fixture = try makeFixture()
        let provider = "oversized-v4"
        let payloadBytes = CmuxAgentSessionRegistry.maximumHookRecordBytes - 2_048
        let records = try (0..<17).map { index in
            try largeRecord(
                provider: provider,
                sessionID: String(format: "old-%02d", index),
                updatedAt: TimeInterval(index),
                payloadBytes: payloadBytes
            )
        }
        try createV4Registry(at: fixture.registry.url, records: records)

        let metrics = try fixture.registry.hookStorageMetrics(provider: provider)
        #expect(metrics.totalBytes <= Int64(CmuxAgentSessionRegistry.maximumHookProviderBytes))
        #expect(metrics.recordCount == 16)
        #expect(try fixture.registry.hookRecord(provider: provider, sessionID: "old-00") == nil)
        #expect(try fixture.registry.hookRecord(provider: provider, sessionID: "old-16") != nil)
    }

    @Test("concurrent readers migrate one existing v4 registry to v5")
    func concurrentExistingRegistryMigrationIsSerialized() async throws {
        let fixture = try makeFixture()
        let provider = "concurrent-v4"
        let stored = try record(
            provider: provider,
            sessionID: "existing",
            workspaceID: "workspace",
            surfaceID: "surface",
            updatedAt: 1
        )
        try createV4Registry(at: fixture.registry.url, records: [stored])

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    let registry = CmuxAgentSessionRegistry(
                        url: fixture.registry.url,
                        busyTimeoutMilliseconds: 2_000
                    )
                    let read = try registry.hookRecord(
                        provider: provider,
                        sessionID: "existing"
                    )
                    #expect(read != nil)
                }
            }
            try await group.waitForAll()
        }
        #expect(try fixture.registry.hookStorageMetrics(provider: provider).recordCount == 1)
    }

    @Test("legacy scanner decodes escaped keys and counts only direct unique runs")
    func legacyScannerHandlesEscapesDuplicatesAndNesting() throws {
        let fixture = try makeFixture()
        let data = Data(#"""
        {
          "nested": {"sessions": {"ignored": {"runs": [{"runId": "ignored"}]}}},
          "sess\u0069ons": {
            "alpha": {
              "runs": [
                {"runId": "same"},
                {"runId": "same"},
                {"run\u0049d": "second", "nested": {"runId": "ignored"}}
              ],
              "nested": {"runs": [{"runId": "ignored"}]}
            },
            "beta": {"runs": []}
          }
        }
        """#.utf8)

        let metrics = try fixture.registry.scanHookLegacySourceData(
            data,
            path: fixture.legacyURL.path
        )
        #expect(metrics.sessionCount == 2)
        #expect(metrics.graphNodeCount == 3)
        #expect(metrics.largestRecordSessionID == "alpha")
    }

    @Test("admitted inspection imports the scanned sidecar revision, not a later rewrite")
    func admittedInspectionPinsScannedLegacyBytes() throws {
        let fixture = try makeFixture()
        let source = CmuxAgentSessionRegistry.LegacySource(
            provider: "codex",
            url: fixture.legacyURL
        )
        func sidecar(sessionID: String) throws -> Data {
            try JSONSerialization.data(
                withJSONObject: [
                    "version": 2,
                    "sessions": [
                        sessionID: [
                            "sessionId": sessionID,
                            "workspaceId": "workspace-\(sessionID)",
                            "surfaceId": "surface-\(sessionID)",
                            "startedAt": 1.0,
                            "updatedAt": 1.0,
                            "runs": [["runId": "run-\(sessionID)"]],
                        ]
                    ],
                ], options: [.sortedKeys])
        }

        try sidecar(sessionID: "admitted").write(to: source.url, options: .atomic)
        let stamp = try #require(CmuxAgentSessionRegistry.LegacyStamp.read(path: source.url.path))
        let admission = try fixture.registry.hookLegacySourceAdmission(
            source: source,
            expectedStamp: stamp
        )
        #expect(admission.wasIssuedByHookLegacyScanner)
        try sidecar(sessionID: "later").write(to: source.url, options: .atomic)

        let snapshot = try #require(
            fixture.registry.snapshotsImportingAdmittedLegacy(
                sources: [source],
                admissions: [admission],
                maximumGraphNodes: 1
            )[source.provider])
        #expect(snapshot.records.map(\.sessionID) == ["admitted"])
        let laterStamp = try #require(
            CmuxAgentSessionRegistry.LegacyStamp.read(path: source.url.path))
        #expect(
            try !fixture.registry.legacySourceIsCurrent(
                provider: source.provider,
                stamp: laterStamp
            ))
    }

    @Test(
        "admitted inspection validates the graph after replacing an unpublished legacy generation")
    func admittedInspectionCountsPostReplacementGraph() throws {
        let fixture = try makeFixture()
        let source = CmuxAgentSessionRegistry.LegacySource(
            provider: "codex",
            url: fixture.legacyURL
        )
        func sidecar(sessionID: String) throws -> Data {
            try JSONSerialization.data(
                withJSONObject: [
                    "version": 2,
                    "sessions": [
                        sessionID: [
                            "sessionId": sessionID,
                            "workspaceId": "workspace-\(sessionID)",
                            "surfaceId": "surface-\(sessionID)",
                            "startedAt": 1.0,
                            "updatedAt": 1.0,
                            "runs": [["runId": "run-\(sessionID)"]],
                        ]
                    ],
                ], options: [.sortedKeys])
        }

        let previous = try sidecar(sessionID: "previous")
        try previous.write(to: source.url, options: .atomic)
        let previousStamp = try #require(
            CmuxAgentSessionRegistry.LegacyStamp.read(
                path: source.url.path
            ))
        try fixture.registry.importLegacyStoreJSON(
            provider: source.provider,
            stamp: previousStamp,
            json: previous
        )

        let replacement = try sidecar(sessionID: "replacement")
        try replacement.write(to: source.url, options: .atomic)
        let replacementStamp = try #require(
            CmuxAgentSessionRegistry.LegacyStamp.read(
                path: source.url.path
            ))
        let admission = try fixture.registry.hookLegacySourceAdmission(
            source: source,
            expectedStamp: replacementStamp
        )
        let snapshot = try #require(
            fixture.registry.snapshotsImportingAdmittedLegacy(
                sources: [source],
                admissions: [admission],
                maximumGraphNodes: 1
            )[source.provider])

        #expect(snapshot.records.map(\.sessionID) == ["replacement"])
    }

    @Test("published projections preserve omitted sessions during admitted graph validation")
    func admittedInspectionPreservesPublishedProjectionOmissions() throws {
        let fixture = try makeFixture()
        let source = CmuxAgentSessionRegistry.LegacySource(
            provider: "codex",
            url: fixture.legacyURL
        )
        func sidecar(sessionID: String) throws -> Data {
            try JSONSerialization.data(
                withJSONObject: [
                    "version": 2,
                    "sessions": [
                        sessionID: [
                            "sessionId": sessionID,
                            "workspaceId": "workspace-\(sessionID)",
                            "surfaceId": "surface-\(sessionID)",
                            "startedAt": 1.0,
                            "updatedAt": 1.0,
                            "runs": [["runId": "run-\(sessionID)"]],
                        ]
                    ],
                ], options: [.sortedKeys])
        }

        let published = try sidecar(sessionID: "published")
        try published.write(to: source.url, options: .atomic)
        let publishedStamp = try #require(
            CmuxAgentSessionRegistry.LegacyStamp.read(
                path: source.url.path
            ))
        try fixture.registry.importLegacyStoreJSON(
            provider: source.provider,
            stamp: publishedStamp,
            json: published
        )
        try fixture.registry.markHookLegacyProjection(
            provider: source.provider,
            revision: 1,
            stamp: publishedStamp
        )

        let partial = try sidecar(sessionID: "partial")
        try partial.write(to: source.url, options: .atomic)
        let partialStamp = try #require(
            CmuxAgentSessionRegistry.LegacyStamp.read(
                path: source.url.path
            ))
        let admission = try fixture.registry.hookLegacySourceAdmission(
            source: source,
            expectedStamp: partialStamp
        )

        #expect(throws: CmuxAgentSessionRegistry.HookInspectionGraphUnionLimitError.self) {
            try fixture.registry.snapshotsImportingAdmittedLegacy(
                sources: [source],
                admissions: [admission],
                maximumGraphNodes: 1
            )
        }
        #expect(
            try fixture.registry.snapshot(provider: source.provider).records.map(\.sessionID)
                == ["published"])
    }

    @Test("admitted inspection validates against canonical rows committed after admission")
    func admittedInspectionUsesLatestCanonicalGraphSnapshot() throws {
        let fixture = try makeFixture()
        let source = CmuxAgentSessionRegistry.LegacySource(
            provider: "codex",
            url: fixture.legacyURL
        )
        let legacy = try JSONSerialization.data(
            withJSONObject: [
                "version": 2,
                "sessions": [
                    "legacy": [
                        "sessionId": "legacy",
                        "workspaceId": "workspace-legacy",
                        "surfaceId": "surface-legacy",
                        "startedAt": 1.0,
                        "updatedAt": 1.0,
                        "runs": [["runId": "legacy-run"]],
                    ]
                ],
            ], options: [.sortedKeys])
        try legacy.write(to: source.url, options: .atomic)
        let stamp = try #require(CmuxAgentSessionRegistry.LegacyStamp.read(path: source.url.path))
        let admission = try fixture.registry.hookLegacySourceAdmission(
            source: source,
            expectedStamp: stamp
        )
        try fixture.registry.apply(
            provider: source.provider,
            records: [
                try record(
                    provider: source.provider,
                    sessionID: "canonical-a",
                    workspaceID: "workspace-a",
                    surfaceID: "surface-a",
                    updatedAt: 2,
                    extra: ["runs": [["runId": "canonical-run-a"]]]
                ),
                try record(
                    provider: source.provider,
                    sessionID: "canonical-b",
                    workspaceID: "workspace-b",
                    surfaceID: "surface-b",
                    updatedAt: 2,
                    extra: ["runs": [["runId": "canonical-run-b"]]]
                ),
            ])

        #expect(throws: CmuxAgentSessionRegistry.HookInspectionGraphUnionLimitError.self) {
            try fixture.registry.snapshotsImportingAdmittedLegacy(
                sources: [source],
                admissions: [admission],
                maximumGraphNodes: 2
            )
        }
        #expect(try fixture.registry.snapshot(provider: source.provider).records.count == 2)
    }

    @Test("graph admission rejects a legacy map key and embedded session mismatch")
    func legacyGraphAdmissionRejectsEmbeddedSessionMismatch() throws {
        let fixture = try makeFixture()
        let source = CmuxAgentSessionRegistry.LegacySource(
            provider: "codex",
            url: fixture.legacyURL
        )
        try Data(#"{"sessions":{"outer":{"sessionId":"inner","runs":[]}}}"#.utf8)
            .write(to: source.url, options: .atomic)
        let stamp = try #require(CmuxAgentSessionRegistry.LegacyStamp.read(path: source.url.path))
        #expect(throws: CmuxAgentSessionRegistry.HookLegacySourceMalformedError.self) {
            try fixture.registry.hookLegacySourceAdmission(
                source: source,
                expectedStamp: stamp
            )
        }
    }

    @Test("bounded legacy reads accept the older flat session-map layout")
    func legacyScannerAcceptsFlatSessionMaps() throws {
        let fixture = try makeFixture()
        let data = Data(#"""
        {
          "version": 1,
          "alpha": {
            "sessionId": "alpha",
            "runs": [{"runId": "first"}, {"runId": "second"}]
          },
          "beta": {"sessionId": "beta", "runs": []}
        }
        """#.utf8)
        try data.write(to: fixture.legacyURL)

        let read = try fixture.registry.readHookLegacySourceData(at: fixture.legacyURL)
        #expect(read == data)
        let metrics = try fixture.registry.hookLegacySourceMetrics(at: fixture.legacyURL)
        #expect(metrics.sessionCount == 2)
        #expect(metrics.graphNodeCount == 3)
        #expect(metrics.largestRecordSessionID == "alpha")
    }

    @Test("graph-node overflow wins a tied session limit in wrapped and flat layouts")
    func legacyScannerTiedLimitsPreferGraphDiagnostics() throws {
        let fixture = try makeFixture()
        let sources = [
            Data(#"{"sessions":{"a":{},"b":{}}}"#.utf8),
            Data(#"{"a":{},"b":{}}"#.utf8),
        ]
        for data in sources {
            var failure: CmuxAgentSessionRegistry.HookLegacySourceInspectionLimitError?
            do {
                _ = try fixture.registry.scanHookLegacySourceData(
                    data,
                    path: fixture.legacyURL.path,
                    maximumSessions: 1,
                    maximumGraphNodes: 1
                )
            } catch let error as CmuxAgentSessionRegistry.HookLegacySourceInspectionLimitError {
                failure = error
            }
            #expect(try #require(failure).scope == .graphNodes)
        }

        var scalarFailure: CmuxAgentSessionRegistry.HookLegacySourceInspectionLimitError?
        do {
            _ = try fixture.registry.scanHookLegacySourceData(
                Data(#"{"metadata-a":1,"metadata-b":2}"#.utf8),
                path: fixture.legacyURL.path,
                maximumSessions: 1,
                maximumGraphNodes: 1
            )
        } catch let error as CmuxAgentSessionRegistry.HookLegacySourceInspectionLimitError {
            scalarFailure = error
        }
        #expect(try #require(scalarFailure).scope == .sessions)
    }

    @Test("legacy scanner rejects malformed strings and truncated nested values")
    func legacyScannerRejectsMalformedJSON() throws {
        let fixture = try makeFixture()
        for malformed in [
            #"{"sessions":{"bad":{"runs":[{"runId":"\q"}]}}}"#,
            #"{"sessions":{"bad":{"nested":[1,2}}}"#,
            #"{"sess\u00ZZions":{}}"#,
        ] {
            #expect(throws: CmuxAgentSessionRegistry.HookLegacySourceMalformedError.self) {
                try fixture.registry.scanHookLegacySourceData(
                    Data(malformed.utf8),
                    path: fixture.legacyURL.path
                )
            }
        }
    }

    @Test("legacy scanner accepts ten thousand nodes and rejects fifty thousand before decode")
    func legacyScannerEnforcesGraphBudgetBeforeDecode() throws {
        let fixture = try makeFixture()
        func source(sessionCount: Int) -> Data {
            let sessions = (0..<sessionCount).map { index in
                #""s\#(index)":{"runs":[]}"#
            }.joined(separator: ",")
            return Data(("{\"sessions\":{" + sessions + "}}").utf8)
        }

        let tenThousand = try fixture.registry.scanHookLegacySourceData(
            source(sessionCount: 10_000),
            path: fixture.legacyURL.path,
            maximumSessions: 20_000,
            maximumGraphNodes: 10_000
        )
        #expect(tenThousand.sessionCount == 10_000)
        #expect(tenThousand.graphNodeCount == 10_000)

        #expect(throws: CmuxAgentSessionRegistry.HookLegacySourceInspectionLimitError.self) {
            try fixture.registry.scanHookLegacySourceData(
                source(sessionCount: 50_000),
                path: fixture.legacyURL.path,
                maximumSessions: 20_000,
                maximumGraphNodes: 20_000
            )
        }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-hot-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Fixture(directory: directory)
    }

    private func record(
        provider: String,
        sessionID: String,
        workspaceID: String,
        surfaceID: String,
        updatedAt: TimeInterval,
        extra: [String: Any] = [:]
    ) throws -> CmuxAgentSessionRegistry.Record {
        var object: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": workspaceID,
            "surfaceId": surfaceID,
            "startedAt": updatedAt,
            "updatedAt": updatedAt,
            "runtimeStatus": "running",
        ]
        object.merge(extra) { _, new in new }
        return CmuxAgentSessionRegistry.Record(
            provider: provider,
            sessionID: sessionID,
            updatedAt: updatedAt,
            json: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    private func largeRecord(
        provider: String,
        sessionID: String,
        updatedAt: TimeInterval,
        payloadBytes: Int
    ) throws -> CmuxAgentSessionRegistry.Record {
        try record(
            provider: provider,
            sessionID: sessionID,
            workspaceID: "workspace-\(sessionID)",
            surfaceID: "surface-\(sessionID)",
            updatedAt: updatedAt,
            extra: ["payload": String(repeating: "x", count: payloadBytes)]
        )
    }

    private func createV4Registry(
        at url: URL,
        records: [CmuxAgentSessionRegistry.Record]
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE agent_sessions (
            provider TEXT NOT NULL,
            session_id TEXT NOT NULL,
            updated_at REAL NOT NULL,
            writer_generation INTEGER NOT NULL,
            workspace_id TEXT,
            surface_id TEXT,
            runtime_id TEXT,
            completed_at REAL,
            restore_authority INTEGER,
            parent_session_id TEXT,
            active_run_id TEXT,
            record_json BLOB NOT NULL,
            PRIMARY KEY (provider, session_id)
        ) WITHOUT ROWID;
        CREATE TABLE agent_active_slots (
            provider TEXT NOT NULL,
            scope TEXT NOT NULL,
            scope_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            updated_at REAL NOT NULL,
            writer_generation INTEGER NOT NULL,
            record_json BLOB NOT NULL,
            PRIMARY KEY (provider, scope, scope_id)
        ) WITHOUT ROWID;
        CREATE TABLE agent_legacy_sources (
            provider TEXT NOT NULL,
            path TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_at REAL NOT NULL,
            imported_at REAL NOT NULL,
            PRIMARY KEY (provider, path)
        ) WITHOUT ROWID;
        CREATE TABLE agent_provider_metadata (
            provider TEXT NOT NULL PRIMARY KEY,
            revision INTEGER NOT NULL DEFAULT 0,
            projected_revision INTEGER NOT NULL DEFAULT 0,
            last_pruned_at REAL NOT NULL DEFAULT 0
        ) WITHOUT ROWID;
        PRAGMA user_version=4;
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw sqliteTestError(database)
        }
        try insertRawRecords(records, provider: records.first?.provider ?? "", database: database)
        guard sqlite3_exec(
            database,
            """
            INSERT INTO agent_provider_metadata (
                provider, revision, projected_revision, last_pruned_at
            ) SELECT provider, 1, 0, 0 FROM agent_sessions GROUP BY provider
            """,
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw sqliteTestError(database)
        }
    }

    private func insertRawRecords(
        _ records: [CmuxAgentSessionRegistry.Record],
        provider: String,
        registryURL: URL,
        createActiveSlots: Bool
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            registryURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        try insertRawRecords(records, provider: provider, database: database)
        guard createActiveSlots else { return }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO agent_active_slots (
            provider, scope, scope_id, session_id, updated_at,
            writer_generation, record_json
        ) VALUES (?1, 'surface', ?2, ?3, ?4, ?5, ?6)
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteTestError(database)
        }
        defer { sqlite3_finalize(statement) }
        for record in records {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, provider, -1, transient)
            sqlite3_bind_text(statement, 2, "slot-\(record.sessionID)", -1, transient)
            sqlite3_bind_text(statement, 3, record.sessionID, -1, transient)
            sqlite3_bind_double(statement, 4, record.updatedAt)
            sqlite3_bind_int64(statement, 5, sqlite3_int64(record.writerGeneration))
            let slotJSON = Data("{\"sessionId\":\"\(record.sessionID)\"}".utf8)
            let result = slotJSON.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 6, bytes.baseAddress, Int32(bytes.count), transient)
            }
            guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteTestError(database)
            }
        }
    }

    private func insertRawRecords(
        _ records: [CmuxAgentSessionRegistry.Record],
        provider: String,
        database: OpaquePointer
    ) throws {
        guard !records.isEmpty else { return }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO agent_sessions (
            provider, session_id, updated_at, writer_generation, record_json
        ) VALUES (?1, ?2, ?3, ?4, ?5)
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteTestError(database)
        }
        defer { sqlite3_finalize(statement) }
        for record in records {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, provider, -1, transient)
            sqlite3_bind_text(statement, 2, record.sessionID, -1, transient)
            sqlite3_bind_double(statement, 3, record.updatedAt)
            sqlite3_bind_int64(statement, 4, sqlite3_int64(record.writerGeneration))
            let result = record.json.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 5, bytes.baseAddress, Int32(bytes.count), transient)
            }
            guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteTestError(database)
            }
        }
    }

    private func sqliteTestError(_ database: OpaquePointer) -> NSError {
        NSError(
            domain: "CmuxAgentSessionRegistryHookHotPathTests",
            code: Int(sqlite3_errcode(database)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
        )
    }

    private func overwriteWorkspaceProjectionMetadata(
        registryURL: URL,
        provider: String,
        sessionID: String,
        workspaceID: String
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            registryURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            """
            UPDATE agent_sessions SET workspace_id = ?1
            WHERE provider = ?2 AND session_id = ?3
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw sqliteTestError(database)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, workspaceID, -1, transient)
        sqlite3_bind_text(statement, 2, provider, -1, transient)
        sqlite3_bind_text(statement, 3, sessionID, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteTestError(database)
        }
    }

    private func executeRegistrySQL(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteTestError(database)
        }
    }

    private func slots(
        provider: String,
        sessionID: String,
        workspaceID: String,
        surfaceID: String,
        updatedAt: TimeInterval
    ) throws -> [CmuxAgentSessionRegistry.ActiveSlot] {
        let json = try JSONSerialization.data(withJSONObject: [
            "sessionId": sessionID,
            "updatedAt": updatedAt,
        ], options: [.sortedKeys])
        return [
            .init(
                provider: provider,
                scope: .workspace,
                scopeID: workspaceID,
                sessionID: sessionID,
                updatedAt: updatedAt,
                json: json
            ),
            .init(
                provider: provider,
                scope: .surface,
                scopeID: surfaceID,
                sessionID: sessionID,
                updatedAt: updatedAt,
                json: json
            ),
        ]
    }
}

private struct StreamingListRecord: Decodable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
}

private struct StreamingListSlot: Decodable {
    var sessionId: String
    var turnId: String?
    var allowsNewSessionReplacement: Bool?
    var updatedAt: TimeInterval
}

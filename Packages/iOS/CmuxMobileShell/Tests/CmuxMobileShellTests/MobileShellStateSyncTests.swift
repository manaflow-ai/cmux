import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

// Behavior tests for mobile state sync v2 (docs/mobile-state-sync-v2.md):
// negotiation via `mobile.sync.fetch`, delta application from
// `mobile.sync.delta` events, legacy fallback on `method_not_found`, and the
// suppression of full-list refetches while v2 is active. Uses the scripted
// liveness host router/transport so events flow through the production
// subscribe/consume path.

private func workspaceRecord(
    id: String,
    title: String,
    customDescription: String? = nil,
    customDescriptionIsTruncated: Bool = false,
    customColorHex: String? = nil,
    sortIndex: Int
) -> WorkspaceSyncRecord {
    WorkspaceSyncRecord(
        id: id,
        windowID: "win-1",
        title: title,
        customDescription: customDescription,
        customDescriptionIsTruncated: customDescriptionIsTruncated,
        customColorHex: customColorHex,
        currentDirectory: nil,
        isSelected: false,
        isPinned: false,
        groupID: nil,
        preview: nil,
        previewAt: nil,
        lastActivityAt: 1.0,
        hasUnread: false,
        sortIndex: sortIndex,
        terminals: []
    )
}

private func syncSnapshotResultData(
    epoch: String,
    rev: UInt64,
    records: [WorkspaceSyncRecord]
) throws -> Data {
    let response = MobileSyncFetchResponse(
        epoch: epoch,
        workspaces: MobileSyncCollectionPayload(
            mode: .snapshot,
            rev: rev,
            fromRev: nil,
            records: records,
            removedIDs: []
        ),
        groups: MobileSyncCollectionPayload(
            mode: .snapshot,
            rev: rev,
            fromRev: nil,
            records: [],
            removedIDs: []
        )
    )
    return try JSONEncoder().encode(response)
}

private func syncDeltaEventFrame(
    epoch: String,
    fromRev: UInt64,
    toRev: UInt64,
    records: [WorkspaceSyncRecord],
    removedIDs: [String] = []
) throws -> Data {
    let event = MobileSyncDeltaEvent(
        epoch: epoch,
        collection: .workspaces,
        fromRev: fromRev,
        toRev: toRev,
        records: records,
        removedIDs: removedIDs
    )
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "mobile.sync.delta",
        "payload": try MobileSyncFrameCoder().jsonObject(from: event),
    ]
    return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
}

private func workspaceUpdatedEventFrame() throws -> Data {
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "workspace.updated",
        "payload": [String: Any](),
    ]
    return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
}

private let workspaceRowActionCapabilities = [
    "events.v1",
    "terminal.render_grid.v1",
    "terminal.replay.v1",
    "workspace.actions.v1",
    "workspace.metadata.v1",
    "workspace.read_state.v1",
    "workspace.close.v1",
]

@MainActor
struct MobileShellStateSyncTests {
    @Test func negotiationAppliesSnapshotAndSuppressesLegacyRefetch() async throws {
        let firstWorkspaceID = UUID().uuidString
        let router = LivenessHostRouter()
        await router.setCapabilities(workspaceRowActionCapabilities)
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 3,
                records: [
                    workspaceRecord(
                        id: firstWorkspaceID,
                        title: "synced-alpha",
                        customDescription: "Release validation",
                        customDescriptionIsTruncated: true,
                        customColorHex: "#1565C0",
                        sortIndex: 0
                    ),
                    workspaceRecord(id: UUID().uuidString, title: "synced-beta", sortIndex: 1),
                ]
            )
        )
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)

        let negotiated = try await pollUntil { store.stateSyncActive }
        #expect(negotiated, "v2 negotiation must complete against a scripted sync host")
        let projected = try await pollUntil {
            store.workspaces.map(\.name).contains("synced-alpha")
        }
        #expect(projected, "snapshot projection must reach the published workspace list")
        let customizedWorkspace = try #require(
            store.workspaces.first(where: { $0.rpcWorkspaceID.rawValue == firstWorkspaceID })
        )
        #expect(customizedWorkspace.customDescription == "Release validation")
        #expect(customizedWorkspace.customDescriptionIsTruncated)
        #expect(customizedWorkspace.customColorHex == "#1565C0")
        #expect(customizedWorkspace.actionCapabilities.supportsWorkspaceActions)
        #expect(customizedWorkspace.actionCapabilities.supportsWorkspaceMetadata)
        #expect(customizedWorkspace.actionCapabilities.supportsReadStateActions)
        #expect(customizedWorkspace.actionCapabilities.supportsCloseActions)

        // A workspace.updated push must no longer trigger the legacy full-list
        // refetch while v2 owns the list.
        let listCallsBefore = await router.count(of: "mobile.workspace.list")
        let transport = try #require(box.get())
        await transport.deliver(try workspaceUpdatedEventFrame())
        // Deliver a delta behind it; its application proves the updated event
        // was consumed first (same stream, in order).
        await transport.deliver(try syncDeltaEventFrame(
            epoch: "epoch-1",
            fromRev: 3,
            toRev: 4,
            records: [
                workspaceRecord(
                    id: firstWorkspaceID,
                    title: "synced-alpha",
                    customDescription: "Ready for launch",
                    customColorHex: "#E91E63",
                    sortIndex: 0
                ),
                workspaceRecord(id: UUID().uuidString, title: "synced-gamma", sortIndex: 2),
            ]
        ))
        let deltaApplied = try await pollUntil {
            let updatedWorkspace = store.workspaces.first {
                $0.rpcWorkspaceID.rawValue == firstWorkspaceID
            }
            return store.workspaces.map(\.name).contains("synced-gamma")
                && updatedWorkspace?.customDescription == "Ready for launch"
                && updatedWorkspace?.customColorHex == "#E91E63"
        }
        #expect(deltaApplied, "contiguous delta must update workspace metadata and extend the mirrored list")
        let updatedWorkspace = try #require(
            store.workspaces.first(where: { $0.rpcWorkspaceID.rawValue == firstWorkspaceID })
        )
        #expect(updatedWorkspace.customDescription == "Ready for launch")
        #expect(updatedWorkspace.customColorHex == "#E91E63")
        let listCallsAfter = await router.count(of: "mobile.workspace.list")
        #expect(
            listCallsAfter == listCallsBefore,
            "workspace.updated must not schedule a full-list refetch while state sync is active"
        )
    }

    @Test func gappedDeltaTriggersCursorRepairFetch() async throws {
        let router = LivenessHostRouter()
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 3,
                records: [workspaceRecord(id: UUID().uuidString, title: "synced-alpha", sortIndex: 0)]
            )
        )
        // The repair fetch answers with the missing span's outcome (snapshot
        // for simplicity; the mirror accepts either).
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 9,
                records: [workspaceRecord(id: UUID().uuidString, title: "repaired", sortIndex: 0)]
            )
        )
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        _ = try await pollUntil { store.stateSyncActive }

        let transport = try #require(box.get())
        // fromRev 7 > mirror rev 3: a gap the shell must repair with a fetch.
        await transport.deliver(try syncDeltaEventFrame(
            epoch: "epoch-1",
            fromRev: 7,
            toRev: 8,
            records: [workspaceRecord(id: UUID().uuidString, title: "lost", sortIndex: 1)]
        ))
        let repaired = try await pollUntil {
            store.workspaces.map(\.name).contains("repaired")
        }
        #expect(repaired, "a gapped delta must trigger a cursor fetch that re-bases the mirror")
        let fetches = await router.count(of: "mobile.sync.fetch")
        #expect(fetches >= 2, "gap repair must issue a second mobile.sync.fetch")
    }

    @Test func removedWorkspaceEvictsSummaryBatchesMapsAndChipImmediately() async throws {
        let removedID = UUID().uuidString
        let keptID = UUID().uuidString
        let router = LivenessHostRouter()
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 3,
                records: [
                    workspaceRecord(id: removedID, title: "removed", sortIndex: 0),
                    workspaceRecord(id: keptID, title: "kept", sortIndex: 1),
                ]
            )
        )
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        _ = try await pollUntil { store.stateSyncActive }
        _ = try await pollUntil {
            store.foregroundWorkspaceChangesIDs.contains(removedID)
        }
        store.workspaceChangesSummaryFetchedAtByWorkspaceID = [
            removedID: clock.now,
            keptID: clock.now,
        ]
        store.workspaceChangesSummaryTrailingExpiryByWorkspaceID = [
            removedID: clock.now.addingTimeInterval(15),
            keptID: clock.now.addingTimeInterval(15),
        ]
        store.setWorkspaceChangeChipsByWorkspaceID([
            removedID: MobileWorkspaceChangesChip(
                filesChanged: 1,
                additions: 2,
                deletions: 3
            ),
            keptID: MobileWorkspaceChangesChip(
                filesChanged: 4,
                additions: 5,
                deletions: 6
            ),
        ])

        let transport = try #require(box.get())
        await transport.deliver(try syncDeltaEventFrame(
            epoch: "epoch-1",
            fromRev: 3,
            toRev: 4,
            records: [],
            removedIDs: [removedID]
        ))
        _ = try await pollUntil {
            !store.foregroundWorkspaceChangesIDs.contains(removedID)
        }
        let batches = store.workspaceChangesSummaryFetchPolicy.batches(
            workspaceIDs: store.foregroundWorkspaceChangesIDs,
            fetchedAtByWorkspaceID: [:],
            now: clock.now,
            force: true
        )

        #expect(batches.flatMap { $0 } == [keptID])
        #expect(Set(store.workspaceChangesSummaryFetchedAtByWorkspaceID.keys) == [keptID])
        #expect(Set(store.workspaceChangesSummaryTrailingExpiryByWorkspaceID.keys) == [keptID])
        #expect(Set(store.workspaceChangeChipsByWorkspaceID.keys) == [keptID])
    }

    @Test func failedRepairFetchFallsBackToLegacyListAndReenablesRefetch() async throws {
        let router = LivenessHostRouter()
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 3,
                records: [workspaceRecord(id: UUID().uuidString, title: "synced-alpha", sortIndex: 0)]
            )
        )
        // The gap-repair fetch fails transiently; the shell must not strand
        // the mirror behind a suppressed refetch loop.
        await router.scriptSyncFetchTransientError()
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        _ = try await pollUntil { store.stateSyncActive }

        let listCallsBefore = await router.count(of: "mobile.workspace.list")
        let transport = try #require(box.get())
        await transport.deliver(try syncDeltaEventFrame(
            epoch: "epoch-1",
            fromRev: 9,
            toRev: 10,
            records: [workspaceRecord(id: UUID().uuidString, title: "lost", sortIndex: 1)]
        ))
        let fellBack = try await pollUntil { !store.stateSyncActive }
        #expect(fellBack, "a failed repair fetch must drop back to legacy semantics")
        let reloaded = try await pollUntil {
            await router.count(of: "mobile.workspace.list") > listCallsBefore
        }
        #expect(reloaded, "the fallback must converge with one authoritative legacy reload")
    }

    @Test func replacingTheForegroundClientDemotesStateSyncAuthority() async throws {
        let router = LivenessHostRouter()
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 3,
                records: [workspaceRecord(id: UUID().uuidString, title: "synced-alpha", sortIndex: 0)]
            )
        )
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        let negotiated = try await pollUntil { store.stateSyncActive }
        #expect(negotiated)

        // Promoting/replacing the foreground client (secondary-to-foreground,
        // reconnect) must implicitly demote v2: the new client's events flow
        // through the legacy invalidation path until ITS negotiation grants
        // authority, so no window exists where the old Mac's authority
        // suppresses the new Mac's updates.
        try installFreshLivenessRemoteClient(on: store, router: router, box: box, clock: clock)
        #expect(store.stateSyncActive == false)
    }

    @Test func transientNegotiationFailureStillRunsTheLegacyReload() async throws {
        // The negotiation fetch itself fails transiently (not method_not_found).
        // Events missed in the subscription gap must still be recovered by the
        // authoritative legacy reload even though authority was never granted.
        let router = LivenessHostRouter()
        await router.scriptSyncFetchTransientError()
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)

        let probed = try await pollUntil {
            await router.count(of: "mobile.sync.fetch") >= 1
        }
        #expect(probed)
        #expect(store.stateSyncActive == false)
        // The connect flow's route binding uses "workspace.list"; only the
        // fallback reload issues "mobile.workspace.list" here.
        let reloaded = try await pollUntil {
            await router.count(of: "mobile.workspace.list") >= 1
        }
        #expect(reloaded, "a transient negotiation failure must trigger the authoritative legacy reload")
    }

    @Test func legacyMacKeepsWorkspaceUpdatedRefetchLoop() async throws {
        // No scripted sync result: the router answers `method_not_found`,
        // modeling a released Mac.
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)

        let probed = try await pollUntil {
            await router.count(of: "mobile.sync.fetch") >= 1
        }
        #expect(probed, "the shell must probe mobile.sync.fetch once per connection")
        #expect(store.stateSyncActive == false)

        let listCallsBefore = await router.count(of: "mobile.workspace.list")
        let transport = try #require(box.get())
        await transport.deliver(try workspaceUpdatedEventFrame())
        let refetched = try await pollUntil {
            await router.count(of: "mobile.workspace.list") > listCallsBefore
        }
        #expect(refetched, "a legacy Mac must keep the workspace.updated refetch loop")
    }

    @Test func foregroundMutationRefreshRunsTrailingFetchForMutationDuringInFlightRefresh() async throws {
        let workspaceID = "live-workspace"
        let router = LivenessHostRouter()
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 3,
                records: [workspaceRecord(id: workspaceID, title: "synced-alpha", sortIndex: 0)]
            )
        )
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 4,
                records: [workspaceRecord(id: workspaceID, title: "synced-beta", sortIndex: 0)]
            )
        )
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 5,
                records: [workspaceRecord(id: workspaceID, title: "synced-gamma", sortIndex: 0)]
            )
        )
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        let negotiated = try await pollUntil {
            store.stateSyncActive
                && store.workspaces.contains { $0.rpcWorkspaceID.rawValue == workspaceID }
        }
        #expect(negotiated, "state sync must settle before the mutation refresh check")
        let foregroundTarget = WorkspaceMutationTarget(
            client: store.remoteClient,
            isForeground: true,
            macDeviceID: store.foregroundMacDeviceID
        )
        let fetchesBefore = await router.count(of: "mobile.sync.fetch")
        #expect(fetchesBefore >= 1)
        await router.holdSyncFetchRequest(number: fetchesBefore + 1)

        let firstRefresh = Task { @MainActor in
            await store.refreshAfterWorkspaceMutation(foregroundTarget)
        }
        let firstRequestStarted = await router.waitForCount(
            of: "mobile.sync.fetch",
            atLeast: fetchesBefore + 1
        )
        #expect(firstRequestStarted, "first foreground mutation refresh must start a state-sync fetch")

        let secondRefresh = Task { @MainActor in
            await store.refreshAfterWorkspaceMutation(foregroundTarget)
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        await router.releaseAllHeld()
        await firstRefresh.value
        await secondRefresh.value

        let trailingReloaded = try await pollUntil {
            await router.count(of: "mobile.sync.fetch") >= fetchesBefore + 2
        }
        #expect(trailingReloaded, "a mutation arriving during an in-flight refresh must trigger one trailing fetch")
    }
}

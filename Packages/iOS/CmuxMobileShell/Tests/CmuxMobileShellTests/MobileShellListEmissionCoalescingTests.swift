import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

// Behavior tests for the workspace-list emission cost work: delta-projection
// coalescing (one projection per window for a burst), equality-guarded store
// writes (no Observation churn for no-op emissions), and the single-flight
// browser-panel refresh (bounded RPCs under a workspace.updated burst).

private func coalescingWorkspaceRecord(
    id: String,
    title: String,
    sortIndex: Int
) -> WorkspaceSyncRecord {
    WorkspaceSyncRecord(
        id: id,
        windowID: "win-1",
        title: title,
        customDescription: nil,
        customDescriptionIsTruncated: false,
        customColorHex: nil,
        currentDirectory: nil,
        isSelected: false,
        isPinned: false,
        groupID: nil,
        preview: nil,
        previewAt: nil,
        lastActivityAt: 1.0,
        hasUnread: false,
        sortIndex: sortIndex,
        terminals: [],
        surfaces: nil
    )
}

private func coalescingSnapshotData(
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

private func coalescingDeltaFrame(
    epoch: String,
    fromRev: UInt64,
    toRev: UInt64,
    records: [WorkspaceSyncRecord]
) throws -> Data {
    let event = MobileSyncDeltaEvent(
        epoch: epoch,
        collection: .workspaces,
        fromRev: fromRev,
        toRev: toRev,
        records: records,
        removedIDs: []
    )
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "mobile.sync.delta",
        "payload": try MobileSyncFrameCoder().jsonObject(from: event),
    ]
    return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
}

private func coalescingWorkspaceUpdatedFrame() throws -> Data {
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "workspace.updated",
        "payload": [String: Any](),
    ]
    return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
}

@MainActor
struct MobileShellListEmissionCoalescingTests {
    /// A burst of contiguous deltas landing inside one coalescing window must
    /// produce exactly one projection (one foreground apply, one Observation
    /// invalidation) whose content reflects the NEWEST delta.
    @Test func burstDeltasProjectOncePerCoalescingWindow() async throws {
        let workspaceID = UUID().uuidString
        let router = LivenessHostRouter()
        await router.scriptSyncFetchResult(
            jsonData: try coalescingSnapshotData(
                epoch: "epoch-1",
                rev: 3,
                records: [coalescingWorkspaceRecord(id: workspaceID, title: "base", sortIndex: 0)]
            )
        )
        let box = TransportBox()
        let clock = TestClock()
        let projectionClock = ControlPoolManualClock()
        let store = try await makeConnectedStore(
            router: router,
            box: box,
            clock: clock,
            stateSyncProjectionClock: projectionClock
        )
        let negotiated = try await pollUntil {
            store.stateSyncActive && store.workspaces.map(\.name).contains("base")
        }
        #expect(negotiated, "v2 negotiation must complete before the burst")

        let revisionBefore = store.foregroundWorkspaceStateRevision
        let transport = try #require(box.get())
        for step in UInt64(3)..<6 {
            await transport.deliver(try coalescingDeltaFrame(
                epoch: "epoch-1",
                fromRev: step,
                toRev: step + 1,
                records: [coalescingWorkspaceRecord(
                    id: workspaceID,
                    title: "rev-\(step + 1)",
                    sortIndex: 0
                )]
            ))
        }
        let mirrored = try await pollUntil {
            store.stateSyncMirror.workspaces.rev == 6
        }
        #expect(mirrored, "all three deltas must reach the mirror")
        // The mirror is delta-exact but nothing projected yet: the flush loop
        // is still sleeping on the held manual clock.
        #expect(
            store.foregroundWorkspaceStateRevision == revisionBefore,
            "no projection may run before the coalescing window elapses"
        )
        #expect(!store.workspaces.map(\.name).contains("rev-6"))

        // The flush task must reach its sleep before the clock advances, or
        // the wake-up deadline lands beyond this advance.
        let flushArmed = try await pollUntil { projectionClock.sleeperCount == 1 }
        #expect(flushArmed, "the coalescing flush must be sleeping on the injected clock")
        projectionClock.advance(by: MobileShellComposite.stateSyncProjectionCoalescingWindow)
        let projected = try await pollUntil {
            store.workspaces.map(\.name).contains("rev-6")
        }
        #expect(projected, "the flush must project the newest delta content")
        #expect(
            store.foregroundWorkspaceStateRevision == revisionBefore &+ 1,
            "a three-delta burst must cost exactly one projection"
        )
        // Wake the trailing sleep so the flush loop can observe the empty
        // pending scope and exit.
        _ = try await pollUntil { projectionClock.sleeperCount == 1 }
        projectionClock.advance(by: MobileShellComposite.stateSyncProjectionCoalescingWindow)
        let flushEnded = try await pollUntil { store.stateSyncProjectionFlushTask == nil }
        #expect(flushEnded, "an empty pending scope must end the flush loop")
    }

    /// Writing an unchanged foreground state through the optimistic-mutation
    /// seam must not invalidate the derived `workspaces` (no topology bump).
    @Test func noOpForegroundMutationDoesNotInvalidateWorkspaces() async throws {
        let store = MobileShellComposite.preview()
        let mutatedVersion: UInt64
        do {
            let versionBefore = store.workspaceTopologyVersion
            store.mutateForegroundWorkspaces { workspaces in
                workspaces = workspaces
            }
            #expect(
                store.workspaceTopologyVersion == versionBefore,
                "a no-op foreground mutation must not fire the didSet re-derivation"
            )
            mutatedVersion = versionBefore
        }
        // A REAL change still propagates (the guard compares content, it does
        // not swallow writes).
        store.mutateForegroundWorkspaces { workspaces in
            workspaces = []
        }
        #expect(
            store.workspaceTopologyVersion != mutatedVersion,
            "a real foreground mutation must still re-derive the aggregate"
        )
    }

    /// A `workspace.updated` burst must coalesce browser-panel refreshes onto
    /// one in-flight RPC plus at most one trailing rerun, instead of one RPC
    /// per event.
    @Test func workspaceUpdatedBurstCoalescesBrowserPanelRefreshes() async throws {
        let workspaceID = UUID().uuidString
        let router = LivenessHostRouter()
        await router.setCapabilities([
            "events.v1",
            MobileShellComposite.browserStreamCapability,
        ])
        await router.scriptSyncFetchResult(
            jsonData: try coalescingSnapshotData(
                epoch: "epoch-1",
                rev: 3,
                records: [coalescingWorkspaceRecord(id: workspaceID, title: "base", sortIndex: 0)]
            )
        )
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        let ready = try await pollUntil {
            store.stateSyncActive
                && store.selectedWorkspace != nil
                && store.supportsBrowserStream
        }
        #expect(ready, "the store must have a selected workspace and browser capability")
        // Let any connect-time panel refresh settle so the held burst below
        // owns the single-flight slot from a clean state.
        let settled = try await pollUntil { store.visibleBrowserPanelsRefreshTask == nil }
        #expect(settled, "no panel refresh may be in flight before the burst")

        await router.holdBrowserListRequests()
        let listCallsBefore = await router.count(of: "mobile.browser.list")
        let transport = try #require(box.get())
        for _ in 0..<5 {
            await transport.deliver(try coalescingWorkspaceUpdatedFrame())
        }
        // All five events land while the first refresh is parked at the
        // router: exactly one RPC is in flight, the rest merged into the
        // trailing slot.
        let inFlight = try await pollUntil {
            await router.count(of: "mobile.browser.list") == listCallsBefore + 1
        }
        #expect(inFlight, "the burst must start exactly one in-flight panel refresh")
        await router.releaseBrowserListRequests()
        let drained = try await pollUntil { store.visibleBrowserPanelsRefreshTask == nil }
        #expect(drained, "the single-flight loop must clear its handle after the trailing rerun")
        let issued = await router.count(of: "mobile.browser.list") - listCallsBefore
        #expect(
            issued == 2,
            "five workspace.updated events must issue one in-flight refresh plus one trailing rerun, got \(issued)"
        )
    }
}

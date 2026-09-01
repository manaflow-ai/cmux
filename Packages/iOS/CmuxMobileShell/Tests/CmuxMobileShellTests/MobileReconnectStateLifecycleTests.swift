import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

// Review-found lifecycle regressions around issue #10482: stale asynchronous
// workspace summaries and public terminal surface-ID reuse.

@Test func retainedMirrorFreshnessFailsClosed() throws {
    var state = MobileTerminalMirrorState()
    let delivered = try MobileTerminalRenderGridFrame(
        surfaceID: "surface",
        stateSeq: 10,
        renderEpoch: "epoch-1",
        renderRevision: 1,
        columns: 80,
        rows: 4,
        full: true,
        rowSpans: [],
        scrollbackRows: 20,
        anchor: .screen,
        historyRows: 20,
        rowSpaceRevision: 1
    )
    state.record(delivered)
    state.prepareForReconnect(hasDeliveredFrame: true)

    var sameHistory = delivered
    sameHistory.stateSeq = 11
    sameHistory.renderRevision = 2
    #expect(!state.requiresHydration(for: sameHistory))

    var advancedHistory = sameHistory
    advancedHistory.historyRows = 21
    #expect(state.requiresHydration(for: advancedHistory))

    var replacedProducer = sameHistory
    replacedProducer.renderEpoch = "epoch-2"
    #expect(state.requiresHydration(for: replacedProducer))
}

@MainActor
@Test func canceledWorkspaceSummaryCannotPublishStaleChips() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities([
        "events.v1",
        "terminal.render_grid.v1",
        "terminal.replay.v1",
        "workspace.changes.v1",
    ])
    let box = TransportBox()
    let clock = TestClock()
    let summaryClock = ControlPoolManualClock()
    let store = try await makeConnectedStore(
        router: router,
        box: box,
        clock: clock,
        workspaceChangesSchedulingClock: summaryClock
    )
    // Keep the automatic capability-triggered debounce from becoming the
    // request under test; this pass owns an explicit generation below.
    store.suspendWorkspaceChangesSummaryFetchesPreservingChips()
    store.setWorkspaceChangeChipsByWorkspaceID([
        "live-workspace": MobileWorkspaceChangesChip(
            filesChanged: 51,
            additions: 120,
            deletions: 8
        ),
    ])
    let responseData = try JSONSerialization.data(withJSONObject: [
        "summaries": [[
            "workspace_id": "live-workspace",
            "is_repo": true,
            "files_changed": 99,
            "additions": 200,
            "deletions": 1,
        ]],
    ])
    await router.enqueueWorkspaceChangesSummaryResponse(jsonData: responseData)
    await router.holdNextWorkspaceChangesSummaryRequests()

    let taskID = UUID()
    store.workspaceChangesSummaryFetchTaskID = taskID
    let fetchTask = Task { @MainActor in
        await store.fetchWorkspaceChangesSummaries(
            workspaceIDs: ["live-workspace"],
            force: true,
            taskID: taskID
        )
    }
    #expect(await router.waitForCount(
        of: "mobile.workspace.changes.summary",
        atLeast: 1
    ))

    // Supersede the in-flight request while its client/state identity still
    // matches. The post-await task-ID guard must prevent its 99-file response
    // from overwriting the authoritative 51-file chip.
    store.workspaceChangesSummaryFetchTaskID = UUID()
    await router.releaseAllHeld()
    await fetchTask.value
    #expect(
        store.workspaceChangeChipsByWorkspaceID["live-workspace"]?.filesChanged == 51,
        "a canceled summary generation must not publish stale chips"
    )
}

@MainActor
@Test func terminalSurfaceIDReuseStartsFreshHydration() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities([
        "events.v1",
        "terminal.render_grid.v1",
        "terminal.render_grid.screen_anchor.v1",
        "terminal.replay.v1",
    ])
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 10,
        renderEpoch: "epoch-1",
        renderRevision: 1,
        columns: 80,
        rows: 4,
        full: true,
        rowSpans: [],
        scrollbackRows: 20,
        anchor: .screen,
        historyRows: 20,
        rowSpaceRevision: 1
    )
    await router.enqueueReplayRenderGrid(frame)
    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    #expect(await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1))
    #expect(try await pollUntil { !collector.lines.isEmpty })

    // Ending the first consumer removes its per-surface lifecycle record.
    collector.unmount()
    #expect(try await pollUntil { !store.hasTerminalOutputSink(surfaceID: surfaceID) })

    let replayCountBeforeRemount = await router.count(of: "mobile.terminal.replay")
    await router.enqueueReplayRenderGrid(frame)
    collector.mount(store: store, surfaceID: surfaceID)
    #expect(await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountBeforeRemount + 1
    ))
    let remountReplay = try #require(await router.requests(for: "mobile.terminal.replay").last)
    #expect(
        (remountReplay.maxScrollbackRows ?? 0) > 0,
        "reusing a surface ID after unregistration must hydrate a fresh mirror"
    )
    collector.unmount()
}

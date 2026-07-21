import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct PaneMapPreviewFetchTests {
    @Test func selectedSurfacesLeadDeduplicatedFourRequestWindow() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let store = MobileShellComposite.preview()
        try installFreshLivenessRemoteClient(
            on: store,
            router: router,
            box: box,
            clock: clock
        )
        let surfaceIDs = ["selected-2", "selected-1", "selected-3", "selected-4", "other-1", "other-2"]
        for (index, surfaceID) in surfaceIDs.enumerated() {
            await router.enqueueReplayRenderGrid(try Self.frame(
                surfaceID: surfaceID,
                stateSeq: UInt64(index + 1)
            ))
        }
        await router.holdNextReplayResponses(count: 4)

        let fetch = Task { @MainActor in
            await store.fetchPaneMapPreviewGrids(
                remoteWorkspaceID: "workspace",
                selectedSurfaceIDs: ["selected-2", "selected-1", "selected-2", "selected-3", "selected-4"],
                remainingSurfaceIDs: ["other-1", "selected-1", "other-2"]
            )
        }
        let filledWindow = await router.waitForCount(
            of: "mobile.terminal.replay",
            atLeast: 4,
            recordIssueOnTimeout: false
        )
        let firstWindow = await router.surfaceIDs(for: "mobile.terminal.replay")
        let requestCountBeforeRelease = await router.count(of: "mobile.terminal.replay")
        await router.releaseAllHeld()
        let grids = await fetch.value
        let allRequestedSurfaceIDs = await router.surfaceIDs(for: "mobile.terminal.replay")

        #expect(filledWindow)
        #expect(requestCountBeforeRelease == 4)
        #expect(Set(firstWindow) == Set(["selected-2", "selected-1", "selected-3", "selected-4"]))
        #expect(allRequestedSurfaceIDs.count == surfaceIDs.count)
        #expect(Set(allRequestedSurfaceIDs) == Set(surfaceIDs))
        #expect(Set(grids.keys) == Set(surfaceIDs))
        await store.remoteClient?.disconnect()
    }

    @Test func cancellationDoesNotStartQueuedRequests() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let store = MobileShellComposite.preview()
        try installFreshLivenessRemoteClient(
            on: store,
            router: router,
            box: box,
            clock: clock
        )
        let surfaceIDs = (1...8).map { "surface-\($0)" }
        for (index, surfaceID) in surfaceIDs.enumerated() {
            await router.enqueueReplayRenderGrid(try Self.frame(
                surfaceID: surfaceID,
                stateSeq: UInt64(index + 1)
            ))
        }
        await router.holdNextReplayResponses(count: 4)

        let fetch = Task { @MainActor in
            await store.fetchPaneMapPreviewGrids(
                remoteWorkspaceID: "workspace",
                selectedSurfaceIDs: [],
                remainingSurfaceIDs: surfaceIDs
            )
        }
        let filledWindow = await router.waitForCount(
            of: "mobile.terminal.replay",
            atLeast: 4,
            recordIssueOnTimeout: false
        )
        fetch.cancel()
        await router.releaseAllHeld()
        _ = await fetch.value
        try await Task.sleep(nanoseconds: 50_000_000)
        let requestedSurfaceIDs = await router.surfaceIDs(for: "mobile.terminal.replay")

        #expect(filledWindow)
        #expect(requestedSurfaceIDs.count == 4)
        await store.remoteClient?.disconnect()
    }

    @Test func connectionReplacementRejectsHeldPreviewResponse() async throws {
        let oldRouter = LivenessHostRouter()
        let oldBox = TransportBox()
        let clock = TestClock()
        let store = MobileShellComposite.preview()
        try installFreshLivenessRemoteClient(
            on: store,
            router: oldRouter,
            box: oldBox,
            clock: clock
        )
        let oldClient = try #require(store.remoteClient)
        await oldRouter.enqueueReplayRenderGrid(try Self.frame(
            surfaceID: "surface-old",
            stateSeq: 1
        ))
        await oldRouter.holdNextReplayResponses()

        let fetch = Task { @MainActor in
            await store.fetchPaneMapPreviewGrid(
                remoteWorkspaceID: "workspace",
                surfaceID: "surface-old"
            )
        }
        let requestStarted = await oldRouter.waitForCount(
            of: "mobile.terminal.replay",
            atLeast: 1,
            recordIssueOnTimeout: false
        )
        let replacementRouter = LivenessHostRouter()
        let replacementBox = TransportBox()
        try installFreshLivenessRemoteClient(
            on: store,
            router: replacementRouter,
            box: replacementBox,
            clock: clock
        )
        await oldRouter.releaseAllHeld()
        let grid = await fetch.value

        #expect(requestStarted)
        #expect(grid == nil)
        await oldClient.disconnect()
        await store.remoteClient?.disconnect()
    }

    private static func frame(
        surfaceID: String,
        stateSeq: UInt64
    ) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            columns: 8,
            rows: 1,
            rowSpans: [.init(row: 0, column: 0, text: surfaceID.prefix(8).description)]
        )
    }
}

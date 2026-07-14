import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@Suite(.serialized)
@MainActor
struct PreviewGridStoreTests {
    @Test func browserPreviewDemandUpgradesToFullAndReleasesOnLastConsumer() async {
        let store = BrowserPreviewStore()
        let preview = store.updates(surfaceID: "browser", resolution: .preview) {}
        let previewConsumer = Task { @MainActor in for await _ in preview {} }
        #expect(store.demand.previewSurfaceIDs == ["browser"])

        let full = store.updates(surfaceID: "browser", resolution: .full) {}
        let fullConsumer = Task { @MainActor in for await _ in full {} }
        #expect(store.demand.fullSurfaceIDs == ["browser"])
        #expect(store.demand.previewSurfaceIDs.isEmpty)

        fullConsumer.cancel()
        await fullConsumer.value
        await expectEventually("full browser demand did not downgrade") {
            store.demand.previewSurfaceIDs == ["browser"]
        }
        previewConsumer.cancel()
        await previewConsumer.value
        await expectEventually("browser demand did not release") {
            store.demand.surfaceIDs.isEmpty
        }
    }

    @Test func multiSurfaceFanoutCoexistsWithMountedFullRateSink() async throws {
        let shell = MobileShellComposite.preview()
        var mounted = shell.terminalOutputStream(surfaceID: "surface-a").makeAsyncIterator()
        var previewA = shell.previewGridUpdates(surfaceID: "surface-a").makeAsyncIterator()
        var previewB = shell.previewGridUpdates(surfaceID: "surface-b").makeAsyncIterator()
        #expect(await previewA.next()?.hasBaseline == false)
        #expect(await previewB.next()?.hasBaseline == false)

        shell.routeIncomingRenderGrid(try frame(surfaceID: "surface-a", seq: 1, text: "alpha"))
        shell.routeIncomingRenderGrid(try frame(surfaceID: "surface-b", seq: 1, text: "beta"))
        for seq in 2...4 {
            shell.routeIncomingRenderGrid(try frame(
                surfaceID: "surface-a",
                seq: UInt64(seq),
                text: "alpha-\(seq)",
                full: false
            ))
        }

        let firstMountedChunk = try #require(await mounted.next())
        shell.terminalOutputDidProcess(
            surfaceID: "surface-a",
            streamToken: firstMountedChunk.streamToken
        )
        let coalescedMountedChunk = try #require(await mounted.next())
        let snapshotA = try #require(await previewA.next())
        let snapshotB = try #require(await previewB.next())
        #expect(!firstMountedChunk.data.isEmpty)
        #expect(!coalescedMountedChunk.data.isEmpty)
        #expect(shell.previewGridSessionState.store.publicationCount(surfaceID: "surface-a") == 1)
        #expect(snapshotA.lines[0].spans.map(\.text) == ["alpha"])
        #expect(snapshotB.lines[0].spans.map(\.text) == ["beta"])
    }

    @Test func burstFramesCoalesceToConfiguredPerSurfaceCap() async throws {
        let store = PreviewGridStore(maximumUpdatesPerSecond: 4)
        var iterator = store.updates(surfaceID: "surface") {}.makeAsyncIterator()
        _ = await iterator.next()
        _ = store.receive(try frame(surfaceID: "surface", seq: 1, text: "one"))
        #expect(await iterator.next()?.stateSeq == 1)
        for seq in 2...20 {
            _ = store.receive(try frame(
                surfaceID: "surface",
                seq: UInt64(seq),
                text: "value-\(seq)",
                full: false
            ))
        }

        #expect(store.publicationCount(surfaceID: "surface") == 1)
        // The throttle defers the burst into one pending publication at the
        // cadence deadline. Awaiting the stream suspends until that timer
        // fires, so the wait is event-driven rather than a wall-clock sleep,
        // and exactly one coalesced publication carries the newest frame.
        #expect(await iterator.next()?.stateSeq == 20)
        #expect(store.publicationCount(surfaceID: "surface") == 2)
    }

    @Test func reconnectResetRequiresFreshFullBaselinePerSurface() async throws {
        let store = PreviewGridStore(maximumUpdatesPerSecond: 4)
        var iterator = store.updates(surfaceID: "surface") {}.makeAsyncIterator()
        _ = await iterator.next()
        _ = store.receive(try frame(surfaceID: "surface", seq: 30, text: "before"))
        #expect(await iterator.next()?.stateSeq == 30)

        store.resetForReconnect()
        #expect(await iterator.next()?.hasBaseline == false)
        let needsBaseline = store.receive(try frame(
            surfaceID: "surface",
            seq: 31,
            text: "delta",
            full: false
        ))
        #expect(needsBaseline)
        _ = store.receive(try frame(
            surfaceID: "surface",
            seq: 1,
            text: "after",
            activeScreen: .alternate
        ))
        let recovered = try #require(await iterator.next())
        #expect(recovered.stateSeq == 1)
        #expect(recovered.activeScreen == .alternate)
    }

    @Test func cancellingLastConsumerUnregistersSurfaceAndReleasesDemand() async throws {
        let shell = MobileShellComposite.preview()
        shell.supportedHostCapabilities = [MobileShellComposite.renderGridDemandCapability]
        let stream = shell.previewGridUpdates(surfaceID: "surface")
        let consumer = Task { @MainActor in
            for await _ in stream {}
        }
        await Task.yield()
        #expect(shell.previewGridSessionState.store.registeredSurfaceIDs == ["surface"])

        consumer.cancel()
        await consumer.value
        await expectEventually("PreviewGridStore termination cleanup did not complete") {
            shell.previewGridSessionState.store.registeredSurfaceIDs.isEmpty
        }
        #expect(shell.previewGridSessionState.store.registeredSurfaceIDs.isEmpty)
        #expect(demandObject(from: shell.terminalEventSubscriptionParameters(
            topics: ["terminal.render_grid"]
        ))?.surfaceIDs.isEmpty == true)
        shell.routeIncomingRenderGrid(try frame(surfaceID: "surface", seq: 1, text: "offscreen"))
        #expect(shell.previewGridSessionState.store.publicationCount(surfaceID: "surface") == 0)
    }

    @Test func demandPayloadSeparatesFocusedAndPreviewSurfacesAndStopsInBackground() {
        let shell = MobileShellComposite.preview()
        shell.supportedHostCapabilities = [MobileShellComposite.renderGridDemandCapability]
        let mountedStream = shell.terminalOutputStream(surfaceID: "focused")
        let focusedPreviewStream = shell.previewGridUpdates(surfaceID: "focused")
        let previewStream = shell.previewGridUpdates(surfaceID: "preview")

        var demand = demandObject(from: shell.terminalEventSubscriptionParameters(
            topics: ["terminal.render_grid"]
        ))
        #expect(demand?.focusedSurfaceIDs == ["focused"])
        #expect(demand?.previewSurfaceIDs == ["preview"])

        shell.previewGridDidSuspendForeground()
        demand = demandObject(from: shell.terminalEventSubscriptionParameters(
            topics: ["terminal.render_grid"]
        ))
        #expect(demand?.isActive == false)
        #expect(demand?.surfaceIDs.isEmpty == true)
        withExtendedLifetime((mountedStream, focusedPreviewStream, previewStream)) {}
    }

    @MainActor
    private func expectEventually(
        _ failureMessage: String,
        maximumYields: Int = 10_000,
        condition: () -> Bool
    ) async {
        for _ in 0..<maximumYields {
            if condition() { return }
            await Task.yield()
        }
        guard !condition() else { return }
        Issue.record("\(failureMessage) after \(maximumYields) task yields")
    }

    private func demandObject(from params: [String: Any]) -> MobileRenderGridDemand? {
        params["render_grid_demand"].flatMap(MobileRenderGridDemand.decodeJSONObject(_:))
    }

    private func frame(
        surfaceID: String,
        seq: UInt64,
        text: String,
        full: Bool = true,
        activeScreen: MobileTerminalRenderGridFrame.Screen = .primary
    ) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: seq,
            columns: 20,
            rows: 2,
            full: full,
            clearedRows: full ? [] : [0],
            rowSpans: [.init(row: 0, column: 0, text: text)],
            activeScreen: activeScreen
        )
    }
}

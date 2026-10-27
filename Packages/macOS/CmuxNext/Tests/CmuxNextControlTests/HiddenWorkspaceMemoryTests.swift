import CmuxNextControl
import CmuxNextMetrics
import CmuxNextWakeups
import Testing

/// Task 061: the main thread's capture of browser tabs becomes a ``MemorySampler`` snapshot with each renderer
/// client id resolved to its pid, and a report trigger's sample is recorded before ``HiddenWorkspaceMemory/sampleNow(_:)``
/// returns. Over a fake capture, pid list and footprint provider.
@MainActor @Suite("Hidden workspace memory sampling")
struct HiddenWorkspaceMemoryTests {
    private typealias Placement = HiddenWorkspaceMemory.Placement

    @Test("Client ids resolve to pids; unknown frames and unlisted renderers are unresolved")
    func clientIDsResolveToPIDs() {
        let capture = HiddenWorkspaceMemory.Capture(tabs: [
            Placement(workspace: "a", rendererFrames: [(clientID: 5, frames: 2), (clientID: 6, frames: 1)]),
            Placement(workspace: "b", rendererFrames: [(clientID: 7, frames: 1)]),
            Placement(workspace: "c", rendererFrames: nil),
            Placement(workspace: "d", rendererFrames: []),
        ], hiddenWorkspaces: ["a", "b", "c", "d"], rendererFrameTotals: [5: 2, 6: 4, 7: 1])

        let snapshot = HiddenWorkspaceMemory.snapshot(capture, pids: [5: 500, 6: 600])

        #expect(snapshot.hiddenWorkspaces == ["a", "b", "c", "d"])
        #expect(snapshot.tabs == [
            MemorySampler.Tab(workspace: "a", renderers: [MemorySampler.RendererShare(pid: 500, frames: 2),
                                                          MemorySampler.RendererShare(pid: 600, frames: 1)]),
            MemorySampler.Tab(workspace: "b", renderers: [], hasUnresolvedFrames: true),
            MemorySampler.Tab(workspace: "c", renderers: [], hasUnresolvedFrames: true),
            MemorySampler.Tab(workspace: "d", renderers: []),
        ])
        #expect(snapshot.rendererFrames == [500: 2, 600: 4], "a renderer with no known pid has no whole count")
    }

    @Test("A shared renderer resolved from client ids splits by every browser's frames, end to end")
    func aSharedRendererSplitsByFrames() {
        // Renderer 9's fourth frame is a same-site popup's, a browser no tab lists.
        let capture = HiddenWorkspaceMemory.Capture(tabs: [
            Placement(workspace: "hidden", rendererFrames: [(clientID: 9, frames: 1)]),
            Placement(workspace: "shown", rendererFrames: [(clientID: 9, frames: 2)]),
        ], hiddenWorkspaces: ["hidden"], rendererFrameTotals: [9: 4])
        let snapshot = HiddenWorkspaceMemory.snapshot(capture, pids: [9: 900])
        #expect(MemorySampler.attribute(snapshot) { _ in 4 * 1_024 * 1_024 } == ["hidden": .clear(kibibytes: 1_024)])
    }

    @Test("Unknown whole frame counts (host mode) leave a shared renderer's split unclear")
    func noTotalsIsUnclear() {
        let capture = HiddenWorkspaceMemory.Capture(tabs: [Placement(workspace: "hidden", rendererFrames: [(clientID: 9, frames: 1)])],
                                                    hiddenWorkspaces: ["hidden"])
        let snapshot = HiddenWorkspaceMemory.snapshot(capture, pids: [9: 900])
        #expect(MemorySampler.attribute(snapshot) { _ in 1_024 } == ["hidden": .unclear(.unknownRendererShare)])
    }

    @Test("A report's sample is counted under its trigger before sampleNow returns")
    func sampleNowRecordsBeforeReturning() async {
        let work = BackgroundWork(label: "test.hidden-workspace-memory")
        let sampler = MemorySampler(footprint: { _ in 1_024 * 1_024 })
        let memory = HiddenWorkspaceMemory(
            sampler: sampler, work: work, mainWork: MainWorkScheduler(budget: MainFrameBudget()),
            capture: { HiddenWorkspaceMemory.Capture(tabs: [Placement(workspace: "w", rendererFrames: [(clientID: 3, frames: 1)])],
                                                     hiddenWorkspaces: ["w"], rendererFrameTotals: [3: 1]) },
            rendererPIDs: { [3: 300] })

        await memory.sampleNow(.report)

        #expect(sampler.tally() == MemorySampler.Tally(recorded: [.report: 1]))
        await work.shutdown()
    }

    @Test("No hidden workspace with a browser tab: nothing is sampled")
    func nothingHiddenSamplesNothing() async {
        let work = BackgroundWork(label: "test.hidden-workspace-memory.none")
        var captures = 0
        let sampler = MemorySampler(footprint: { _ in 1 })
        let memory = HiddenWorkspaceMemory(
            sampler: sampler, work: work, mainWork: MainWorkScheduler(budget: MainFrameBudget()),
            capture: {
                captures += 1
                return HiddenWorkspaceMemory.Capture(tabs: [Placement(workspace: "shown", rendererFrames: [])])
            },
            rendererPIDs: { [:] })

        await memory.sampleNow(.report)

        #expect(captures == 1)
        #expect(sampler.tally() == MemorySampler.Tally())
        await work.shutdown()
    }
}

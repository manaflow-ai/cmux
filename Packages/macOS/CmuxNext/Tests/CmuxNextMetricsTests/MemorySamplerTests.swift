import CmuxNextMetrics
import CmuxNextTrace
import Darwin
import Testing

/// `memory.hidden_workspace_kib` (p09-observability task 061) over a fake footprint provider: a hidden workspace's
/// renderers are split by frames, a renderer shared with a shown or another hidden workspace counts by the
/// workspace's share of its frames, and a workspace whose attribution is unclear records nothing and is counted
/// under its trigger.
@Suite("Memory per hidden workspace")
struct MemorySamplerTests {
    private typealias Tab = MemorySampler.Tab
    private typealias Share = MemorySampler.RendererShare

    private static let mebibyte: UInt64 = 1_024 * 1_024

    /// A sampler over a fresh store, its store, and footprints in bytes by pid (a pid not listed is unreadable).
    private static func sampler(footprints: [Int32: UInt64]) -> (MemorySampler, MetricsStore) {
        let runtime = TraceRuntime(role: .app)
        let profile = MetricsProfile(appVersion: "1.2.3", buildNumber: "45", channel: "nightly", osVersion: "26.1.0",
                                     hardwareClass: "Mac16,10", bootSessionUUID: Array(0 ..< 16), buildUUID: Array(16 ..< 32),
                                     buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))
        let store = MetricsStore(role: .app, profile: profile, pid: 4242)
        #expect(store.attach(to: runtime))
        return (MemorySampler(metrics: Metrics(runtime: runtime), footprint: { footprints[$0] }), store)
    }

    private static func histogram(in store: MetricsStore) -> MetricsDelta.Histogram? {
        store.delta().histograms.first { $0.name == HistogramID.memoryHiddenWorkspace.name }
    }

    @Test("A hidden workspace's own renderers are its memory, in KiB")
    func ownRenderersAreTheWorkspacesMemory() {
        let (sampler, store) = Self.sampler(footprints: [10: 10 * Self.mebibyte, 11: 2 * Self.mebibyte])
        let snapshot = MemorySampler.Snapshot(tabs: [
            Tab(workspace: "w1", renderers: [Share(pid: 10, frames: 3), Share(pid: 11, frames: 1)]),
            Tab(workspace: "shown", renderers: [Share(pid: 12, frames: 1)]),
        ], hiddenWorkspaces: ["w1"])

        let found = sampler.sample(snapshot, trigger: .workspaceSwitch)

        #expect(found == ["w1": .clear(kibibytes: 12 * 1_024)], "a shown workspace gets no sample")
        let histogram = Self.histogram(in: store)
        #expect(histogram?.count == 1 && histogram?.sum == 12 * 1_024)
        #expect(sampler.tally() == MemorySampler.Tally(recorded: [.workspaceSwitch: 1]))
    }

    @Test("A renderer shared with a shown tab counts by the share of its frames that are hidden")
    func sharedWithAShownTabCountsByHiddenFrames() {
        let (sampler, store) = Self.sampler(footprints: [20: 8 * Self.mebibyte])
        let snapshot = MemorySampler.Snapshot(tabs: [
            Tab(workspace: "hidden", renderers: [Share(pid: 20, frames: 1)]),
            Tab(workspace: "shown", renderers: [Share(pid: 20, frames: 3)]),
        ], hiddenWorkspaces: ["hidden"])

        #expect(sampler.sample(snapshot, trigger: .resignActive) == ["hidden": .clear(kibibytes: 2 * 1_024)])
        #expect(Self.histogram(in: store)?.sum == 2 * 1_024)
    }

    @Test("A renderer shared by two hidden workspaces is split between them, whole")
    func sharedByTwoHiddenWorkspacesIsSplit() {
        let (sampler, store) = Self.sampler(footprints: [30: 9 * Self.mebibyte])
        let snapshot = MemorySampler.Snapshot(tabs: [
            Tab(workspace: "a", renderers: [Share(pid: 30, frames: 2)]),
            Tab(workspace: "b", renderers: [Share(pid: 30, frames: 1)]),
            Tab(workspace: "a", renderers: [Share(pid: 30, frames: 3)]),
        ], hiddenWorkspaces: ["a", "b"])

        let found = sampler.sample(snapshot, trigger: .report)

        #expect(found == ["a": .clear(kibibytes: 9 * 1_024 * 5 / 6), "b": .clear(kibibytes: 9 * 1_024 / 6)])
        #expect(Self.histogram(in: store)?.count == 2)
        #expect(Self.histogram(in: store)?.sum == 9 * 1_024)
        #expect(sampler.tally() == MemorySampler.Tally(recorded: [.report: 2]))
    }

    @Test("A frame with no known renderer makes the workspace unclear: counted, not recorded")
    func unresolvedFramesAreUnclear() {
        let (sampler, store) = Self.sampler(footprints: [40: Self.mebibyte, 41: Self.mebibyte])
        let snapshot = MemorySampler.Snapshot(tabs: [
            Tab(workspace: "w", renderers: [Share(pid: 40, frames: 1)]),
            Tab(workspace: "w", renderers: [], hasUnresolvedFrames: true),
            Tab(workspace: "clear", renderers: [Share(pid: 41, frames: 1)]),
        ], hiddenWorkspaces: ["w", "clear"])

        let found = sampler.sample(snapshot, trigger: .workspaceSwitch)

        #expect(found == ["w": .unclear(.unresolvedFrames), "clear": .clear(kibibytes: 1_024)])
        #expect(Self.histogram(in: store)?.count == 1, "only the clear workspace records")
        #expect(sampler.tally() == MemorySampler.Tally(recorded: [.workspaceSwitch: 1], unclear: [.workspaceSwitch: 1]))
    }

    @Test("A renderer whose footprint cannot be read makes its workspace unclear")
    func unreadableFootprintIsUnclear() {
        let (sampler, store) = Self.sampler(footprints: [:])
        let snapshot = MemorySampler.Snapshot(tabs: [Tab(workspace: "w", renderers: [Share(pid: 50, frames: 1)])],
                                              hiddenWorkspaces: ["w"])

        #expect(sampler.sample(snapshot, trigger: .resignActive) == ["w": .unclear(.unreadableFootprint)])
        #expect(Self.histogram(in: store) == nil)
        #expect(sampler.tally() == MemorySampler.Tally(unclear: [.resignActive: 1]))
    }

    @Test("A hidden tab with no frames holds no renderer memory: a clear 0")
    func noFramesIsAClearZero() {
        let (sampler, _) = Self.sampler(footprints: [:])
        let snapshot = MemorySampler.Snapshot(tabs: [Tab(workspace: "w", renderers: [])], hiddenWorkspaces: ["w"])
        #expect(sampler.sample(snapshot, trigger: .workspaceSwitch) == ["w": .clear(kibibytes: 0)])
    }

    @Test("Each renderer's footprint is read once per sample, however many workspaces share it")
    func eachFootprintIsReadOnce() {
        var reads: [Int32] = []
        let snapshot = MemorySampler.Snapshot(tabs: [
            Tab(workspace: "a", renderers: [Share(pid: 60, frames: 1), Share(pid: 61, frames: 1)]),
            Tab(workspace: "b", renderers: [Share(pid: 60, frames: 1)]),
            Tab(workspace: "c", renderers: [Share(pid: 60, frames: 1)]),
        ], hiddenWorkspaces: ["a", "b", "c"])

        let found = MemorySampler.attribute(snapshot) { pid in
            reads.append(pid)
            return 3 * Self.mebibyte
        }

        #expect(reads.sorted() == [60, 61])
        #expect(found["b"] == .clear(kibibytes: 1_024) && found["a"] == .clear(kibibytes: 1_024 + 3 * 1_024))
    }

    @Test("A tab of an unknown workspace still counts in its renderer's frames")
    func unknownWorkspaceFramesCountInTheTotal() {
        let snapshot = MemorySampler.Snapshot(tabs: [
            Tab(workspace: "hidden", renderers: [Share(pid: 70, frames: 1)]),
            Tab(workspace: nil, renderers: [Share(pid: 70, frames: 1)]),
        ], hiddenWorkspaces: ["hidden"])
        #expect(MemorySampler.attribute(snapshot) { _ in 4 * Self.mebibyte } == ["hidden": .clear(kibibytes: 2 * 1_024)])
    }

    @Test("Our own process's footprint reads; a pid that is no process does not")
    func physicalFootprintReadsThisProcess() {
        #expect((MemorySampler.physicalFootprint(of: getpid()) ?? 0) > 0)
        #expect(MemorySampler.physicalFootprint(of: -1) == nil)
    }
}

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

    /// A snapshot of `tabs` whose renderers' whole frame counts are the frames `tabs` put in them plus `unlisted`
    /// (by pid: frames of browsers no tab lists, a popup, a spare).
    private static func snapshot(_ tabs: [Tab], hidden: Set<String>, unlisted: [Int32: Int] = [:]) -> MemorySampler.Snapshot {
        var whole = unlisted
        for share in tabs.flatMap(\.renderers) { whole[share.pid, default: 0] += share.frames }
        return MemorySampler.Snapshot(tabs: tabs, hiddenWorkspaces: hidden, rendererFrames: whole)
    }

    private static func histogram(in store: MetricsStore) -> MetricsDelta.Histogram? {
        store.delta().histograms.first { $0.name == HistogramID.memoryHiddenWorkspace.name }
    }

    @Test("A hidden workspace's own renderers are its memory, in KiB")
    func ownRenderersAreTheWorkspacesMemory() {
        let (sampler, store) = Self.sampler(footprints: [10: 10 * Self.mebibyte, 11: 2 * Self.mebibyte])
        let snapshot = Self.snapshot([
            Tab(workspace: "w1", renderers: [Share(pid: 10, frames: 3), Share(pid: 11, frames: 1)]),
            Tab(workspace: "shown", renderers: [Share(pid: 12, frames: 1)]),
        ], hidden: ["w1"])

        let found = sampler.sample(snapshot, trigger: .workspaceSwitch)

        #expect(found == ["w1": .clear(kibibytes: 12 * 1_024)], "a shown workspace gets no sample")
        let histogram = Self.histogram(in: store)
        #expect(histogram?.count == 1 && histogram?.sum == 12 * 1_024)
        #expect(sampler.tally() == MemorySampler.Tally(recorded: [.workspaceSwitch: 1]))
    }

    @Test("A renderer shared with a shown tab counts by the share of its frames that are hidden")
    func sharedWithAShownTabCountsByHiddenFrames() {
        let (sampler, store) = Self.sampler(footprints: [20: 8 * Self.mebibyte])
        let snapshot = Self.snapshot([
            Tab(workspace: "hidden", renderers: [Share(pid: 20, frames: 1)]),
            Tab(workspace: "shown", renderers: [Share(pid: 20, frames: 3)]),
        ], hidden: ["hidden"])

        #expect(sampler.sample(snapshot, trigger: .resignActive) == ["hidden": .clear(kibibytes: 2 * 1_024)])
        #expect(Self.histogram(in: store)?.sum == 2 * 1_024)
    }

    @Test("A renderer shared by two hidden workspaces is split between them, whole")
    func sharedByTwoHiddenWorkspacesIsSplit() {
        let (sampler, store) = Self.sampler(footprints: [30: 9 * Self.mebibyte])
        let snapshot = Self.snapshot([
            Tab(workspace: "a", renderers: [Share(pid: 30, frames: 2)]),
            Tab(workspace: "b", renderers: [Share(pid: 30, frames: 1)]),
            Tab(workspace: "a", renderers: [Share(pid: 30, frames: 3)]),
        ], hidden: ["a", "b"])

        let found = sampler.sample(snapshot, trigger: .report)

        let whole: Int64 = 9 * 1_024
        let expected: [String: MemorySampler.Attribution] = ["a": .clear(kibibytes: whole * 5 / 6), "b": .clear(kibibytes: whole / 6)]
        #expect(found == expected)
        #expect(Self.histogram(in: store)?.count == 2)
        #expect(Self.histogram(in: store)?.sum == 9 * 1_024)
        #expect(sampler.tally() == MemorySampler.Tally(recorded: [.report: 2]))
    }

    @Test("A frame with no known renderer makes the workspace unclear: counted, not recorded")
    func unresolvedFramesAreUnclear() {
        let (sampler, store) = Self.sampler(footprints: [40: Self.mebibyte, 41: Self.mebibyte])
        let snapshot = Self.snapshot([
            Tab(workspace: "w", renderers: [Share(pid: 40, frames: 1)]),
            Tab(workspace: "w", renderers: [], hasUnresolvedFrames: true),
            Tab(workspace: "clear", renderers: [Share(pid: 41, frames: 1)]),
        ], hidden: ["w", "clear"])

        let found = sampler.sample(snapshot, trigger: .workspaceSwitch)

        #expect(found == ["w": .unclear(.unresolvedFrames), "clear": .clear(kibibytes: 1_024)])
        #expect(Self.histogram(in: store)?.count == 1, "only the clear workspace records")
        #expect(sampler.tally() == MemorySampler.Tally(recorded: [.workspaceSwitch: 1], unclear: [.workspaceSwitch: 1]))
    }

    @Test("A renderer whose footprint cannot be read makes its workspace unclear")
    func unreadableFootprintIsUnclear() {
        let (sampler, store) = Self.sampler(footprints: [:])
        let snapshot = Self.snapshot([Tab(workspace: "w", renderers: [Share(pid: 50, frames: 1)])],
                                              hidden: ["w"])

        #expect(sampler.sample(snapshot, trigger: .resignActive) == ["w": .unclear(.unreadableFootprint)])
        #expect(Self.histogram(in: store) == nil)
        #expect(sampler.tally() == MemorySampler.Tally(unclear: [.resignActive: 1]))
    }

    @Test("A hidden tab with no frames holds no renderer memory: a clear 0")
    func noFramesIsAClearZero() {
        let (sampler, _) = Self.sampler(footprints: [:])
        let snapshot = Self.snapshot([Tab(workspace: "w", renderers: [])], hidden: ["w"])
        #expect(sampler.sample(snapshot, trigger: .workspaceSwitch) == ["w": .clear(kibibytes: 0)])
    }

    @Test("Each renderer's footprint is read once per sample, however many workspaces share it")
    func eachFootprintIsReadOnce() {
        var reads: [Int32] = []
        let snapshot = Self.snapshot([
            Tab(workspace: "a", renderers: [Share(pid: 60, frames: 1), Share(pid: 61, frames: 1)]),
            Tab(workspace: "b", renderers: [Share(pid: 60, frames: 1)]),
            Tab(workspace: "c", renderers: [Share(pid: 60, frames: 1)]),
        ], hidden: ["a", "b", "c"])

        let found = MemorySampler.attribute(snapshot) { pid in
            reads.append(pid)
            return 3 * Self.mebibyte
        }

        #expect(reads.sorted() == [60, 61])
        #expect(found["b"] == .clear(kibibytes: 1_024) && found["a"] == .clear(kibibytes: 1_024 + 3 * 1_024))
    }

    @Test("A tab of an unknown workspace still counts in its renderer's frames")
    func unknownWorkspaceFramesCountInTheTotal() {
        let snapshot = Self.snapshot([
            Tab(workspace: "hidden", renderers: [Share(pid: 70, frames: 1)]),
            Tab(workspace: nil, renderers: [Share(pid: 70, frames: 1)]),
        ], hidden: ["hidden"])
        #expect(MemorySampler.attribute(snapshot) { _ in 4 * Self.mebibyte } == ["hidden": .clear(kibibytes: 2 * 1_024)])
    }

    @Test("Frames of a browser no tab lists (a same-site popup) count in the split: the hidden share is not overcounted")
    func unlistedBrowserFramesCountInTheSplit() {
        let snapshot = Self.snapshot([Tab(workspace: "hidden", renderers: [Share(pid: 80, frames: 1)])],
                                     hidden: ["hidden"], unlisted: [80: 3])
        #expect(MemorySampler.attribute(snapshot) { _ in 8 * Self.mebibyte } == ["hidden": .clear(kibibytes: 2 * 1_024)])
    }

    @Test("A renderer with no whole frame count (shared with an unlisted or unresolved browser) gives no clear sample")
    func noWholeFrameCountIsUnclear() {
        let (sampler, store) = Self.sampler(footprints: [81: 4 * Self.mebibyte, 82: Self.mebibyte])
        let tabs = [Tab(workspace: "shared", renderers: [Share(pid: 81, frames: 1)]),
                    Tab(workspace: "own", renderers: [Share(pid: 82, frames: 1)])]
        let snapshot = MemorySampler.Snapshot(tabs: tabs, hiddenWorkspaces: ["shared", "own"], rendererFrames: [82: 1])

        let found = sampler.sample(snapshot, trigger: .workspaceSwitch)

        #expect(found == ["shared": .unclear(.unknownRendererShare), "own": .clear(kibibytes: 1_024)])
        #expect(Self.histogram(in: store)?.count == 1, "only the workspace with whole counts records")
        #expect(sampler.tally() == MemorySampler.Tally(recorded: [.workspaceSwitch: 1], unclear: [.workspaceSwitch: 1]))
    }

    @Test("A whole frame count below the listed tabs' frames is not whole: every hidden workspace in it is unclear")
    func aShortWholeCountIsUnclear() {
        let tabs = [Tab(workspace: "a", renderers: [Share(pid: 83, frames: 2)]),
                    Tab(workspace: "b", renderers: [Share(pid: 83, frames: 2)])]
        let snapshot = MemorySampler.Snapshot(tabs: tabs, hiddenWorkspaces: ["a", "b"], rendererFrames: [83: 3])
        #expect(MemorySampler.attribute(snapshot) { _ in Self.mebibyte }
            == ["a": .unclear(.unknownRendererShare), "b": .unclear(.unknownRendererShare)])
    }

    @Test("Our own process's footprint reads; a pid that is no process does not")
    func physicalFootprintReadsThisProcess() {
        #expect((MemorySampler.physicalFootprint(of: getpid()) ?? 0) > 0)
        #expect(MemorySampler.physicalFootprint(of: -1) == nil)
    }
}

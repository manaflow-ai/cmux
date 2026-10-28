public import CmuxNextMetrics
public import CmuxNextWakeups

/// When `memory.hidden_workspace_kib` is sampled, and what each sample reads (task 061,
/// plans/cmux-next/chrome-parity/p09-observability.md): at a workspace switch, when the app resigns active, and
/// before a hang report is built. No timer: the sampling moments are the transitions, so the samples are not
/// biased toward report times.
///
/// A transition's sample waits for the main thread's idle time (``workspaceDidShow()``, ``appDidResignActive()``): the main thread only reads which
/// workspace holds each browser tab, which workspaces no window shows and every browser's renderer frames (the
/// App's ``Capture``, O(browser frames), one in-process shim call); the renderer pids, their footprints and
/// the attribution (``MemorySampler``) run on a background lane. Transitions that come before that idle time
/// join the first one's sample, under its trigger.
///
/// The App makes one with its hang reports, which call ``sampleNow(_:)`` before a report; its window manager and
/// its resign-active subscription call ``workspaceDidShow()`` and ``appDidResignActive()``. Tests pass a fake
/// capture and pid list.
@MainActor public final class HiddenWorkspaceMemory {
    /// One browser tab as the main thread sees it.
    public struct Placement: Sendable {
        /// The workspace that holds it; nil when unknown.
        public var workspace: String?
        /// Each renderer client id hosting its frames, with how many of its frames it hosts (`CEFRendererFrames`);
        /// empty for a tab with no engine page (hibernated, deferred, no browser yet), which holds no renderer
        /// memory; nil when unknown (a live page of another engine, host mode).
        public var rendererFrames: [(clientID: Int32, frames: Int)]?

        public init(workspace: String?, rendererFrames: [(clientID: Int32, frames: Int)]?) {
            self.workspace = workspace
            self.rendererFrames = rendererFrames
        }
    }

    /// Every browser tab, the workspaces with one that no window shows now, and each renderer's frames.
    public struct Capture: Sendable {
        public var tabs: [Placement]
        public var hiddenWorkspaces: Set<String>
        /// Every frame each renderer hosts, by renderer client id, over every browser of the engine (popups,
        /// popup windows, spares, DevTools: browsers ``tabs`` does not list). Empty when unknown, which leaves
        /// every renderer's split unclear.
        public var rendererFrameTotals: [Int32: Int]

        public init(tabs: [Placement] = [], hiddenWorkspaces: Set<String> = [], rendererFrameTotals: [Int32: Int] = [:]) {
            self.tabs = tabs
            self.hiddenWorkspaces = hiddenWorkspaces
            self.rendererFrameTotals = rendererFrameTotals
        }
    }

    /// Records the samples and counts them per trigger.
    public let sampler: MemorySampler
    private let work: BackgroundWork
    private let mainWork: MainWorkScheduler
    private let capture: @MainActor () -> Capture
    private let rendererPIDs: @Sendable () -> [Int32: Int32]
    /// The trigger of the sample waiting for idle time; nil when none waits.
    private var pending: MemorySampler.Trigger?

    /// - Parameters:
    ///   - sampler: Attributes and records the samples.
    ///   - work: Runs the pid lookup, the footprint reads and the attribution (lane `system`).
    ///   - mainWork: Gives a transition's sample the main thread's idle time.
    ///   - capture: The browser tabs and hidden workspaces now, on the main thread.
    ///   - rendererPIDs: Each tab renderer's pid by its renderer client id, off the main thread (the helpers' argv).
    public init(sampler: MemorySampler = MemorySampler(), work: BackgroundWork, mainWork: MainWorkScheduler,
                capture: @escaping @MainActor () -> Capture, rendererPIDs: @escaping @Sendable () -> [Int32: Int32]) {
        self.sampler = sampler
        self.work = work
        self.mainWork = mainWork
        self.capture = capture
        self.rendererPIDs = rendererPIDs
    }

    /// A window showed a workspace and hid the one it showed.
    public func workspaceDidShow() {
        note(.workspaceSwitch)
    }

    /// The app stopped being the active app (told by the app's one resign-active subscription).
    public func appDidResignActive() {
        note(.resignActive)
    }

    /// A transition: one sample in the main thread's next idle time (at most 5 s later), under `trigger` unless a
    /// sample already waits, which this one joins.
    private func note(_ trigger: MemorySampler.Trigger) {
        guard pending == nil else { return }
        pending = trigger
        mainWork.postIdle(owner: "HiddenWorkspaceMemory", maxDelay: .seconds(5)) { [weak self] _ in
            guard let self, let trigger = pending else { return }
            pending = nil
            guard let capture = hiddenCapture() else { return }
            let sampler = self.sampler, rendererPIDs = self.rendererPIDs
            work.post(.bestEffort, mayBlock: .system) {
                _ = sampler.sample(HiddenWorkspaceMemory.snapshot(capture, pids: rendererPIDs()), trigger: trigger)
            }
        }
    }

    /// A sample now, under `trigger` (a report about to be built): returns once it is recorded, so the report
    /// carries it.
    public func sampleNow(_ trigger: MemorySampler.Trigger) async {
        guard let capture = hiddenCapture() else { return }
        let sampler = self.sampler, rendererPIDs = self.rendererPIDs
        _ = try? await work.run(.userVisible, mayBlock: .system) {
            sampler.sample(HiddenWorkspaceMemory.snapshot(capture, pids: rendererPIDs()), trigger: trigger)
        }
    }

    /// The capture, or nil when no hidden workspace has a browser tab (nothing to sample).
    private func hiddenCapture() -> Capture? {
        let capture = capture()
        return capture.hiddenWorkspaces.isEmpty ? nil : capture
    }

    /// `capture` with each renderer client id resolved to its pid through `pids` (client id to pid). A tab whose
    /// frames are unknown, or that has a frame in a renderer `pids` does not list (a helper not exec'd yet, a
    /// Chromium Host's child), has unresolved frames, which makes its workspace's sample unclear. A renderer
    /// whose pid is unknown has no whole frame count in the snapshot.
    public nonisolated static func snapshot(_ capture: Capture, pids: [Int32: Int32]) -> MemorySampler.Snapshot {
        let tabs = capture.tabs.map { placement -> MemorySampler.Tab in
            guard let frames = placement.rendererFrames else {
                return MemorySampler.Tab(workspace: placement.workspace, renderers: [], hasUnresolvedFrames: true)
            }
            var renderers: [MemorySampler.RendererShare] = []
            var unresolved = false
            for entry in frames {
                if let pid = pids[entry.clientID] {
                    renderers.append(MemorySampler.RendererShare(pid: pid, frames: entry.frames))
                } else {
                    unresolved = true
                }
            }
            return MemorySampler.Tab(workspace: placement.workspace, renderers: renderers, hasUnresolvedFrames: unresolved)
        }
        var rendererFrames: [Int32: Int] = [:]
        for (clientID, frames) in capture.rendererFrameTotals {
            if let pid = pids[clientID] { rendererFrames[pid, default: 0] += frames }
        }
        return MemorySampler.Snapshot(tabs: tabs, hiddenWorkspaces: capture.hiddenWorkspaces, rendererFrames: rendererFrames)
    }
}

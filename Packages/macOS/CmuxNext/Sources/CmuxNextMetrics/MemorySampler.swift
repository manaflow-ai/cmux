import CmuxNextCompat
import Darwin

/// The memory each hidden workspace holds in Chromium renderers, as `memory.hidden_workspace_kib`
/// (plans/cmux-next/chrome-parity/p09-observability.md, task 061).
///
/// A sample sums the physical footprint (`ri_phys_footprint`) of the renderers that host a hidden workspace's
/// browser tabs. Same-site tabs can share one renderer, also across a hidden and a shown workspace, so a
/// renderer's footprint is split by frames: a workspace gets the share of the renderer's frames that are its
/// own. Chrome attributes a process's memory to its pages the same way, an equal part per frame the process
/// hosts (components/performance_manager/resource_attribution/attribution_helpers.h,
/// `SplitResourceAmongFramesAndWorkers`).
///
/// A workspace records a sample only when its attribution is clear: every frame of its tabs has a renderer with
/// a known pid, each of those renderers' whole frame count (every browser's, popups too) is known, and each of
/// their footprints was read. Any other workspace is counted as unclear, by
/// the sample's ``Trigger``, and records nothing, so the histogram is never biased by guesses. Samples are taken
/// at transitions only (a workspace switch, the app resigning active, a report): no timer.
///
/// ```swift
/// let sampler = MemorySampler()
/// sampler.sample(snapshot, trigger: .workspaceSwitch)  // off the main thread: one system call per renderer
/// ```
public final class MemorySampler: Sendable {
    /// What caused a sample. Each is counted on its own (``tally()``), so a report can tell a bias toward
    /// one trigger.
    public enum Trigger: Int, Sendable, CaseIterable {
        /// A window showed another workspace and hid the one it showed.
        case workspaceSwitch
        /// The app stopped being the active app.
        case resignActive
        /// A hang report is built (a MetricKit delivery, View Hang Report).
        case report

        /// The trigger's name in reports.
        public var name: String {
            switch self {
            case .workspaceSwitch: "workspace_switch"
            case .resignActive: "resign_active"
            case .report: "report"
            }
        }
    }

    /// One renderer's part of a tab: the renderer's pid and how many of the tab's frames it hosts.
    public struct RendererShare: Sendable, Hashable {
        public var pid: Int32
        public var frames: Int

        public init(pid: Int32, frames: Int) {
            self.pid = pid
            self.frames = frames
        }
    }

    /// One browser tab when the sample is taken.
    public struct Tab: Sendable, Equatable {
        /// The workspace that holds it; nil when unknown (its frames still count in their renderers' totals).
        public var workspace: String?
        /// The renderers that host its frames.
        public var renderers: [RendererShare]
        /// Whether some of its frames are in no listed renderer: a renderer whose pid is unknown, a page of
        /// another engine, more renderers than the shim returns, or host mode.
        public var hasUnresolvedFrames: Bool

        public init(workspace: String?, renderers: [RendererShare], hasUnresolvedFrames: Bool = false) {
            self.workspace = workspace
            self.renderers = renderers
            self.hasUnresolvedFrames = hasUnresolvedFrames
        }
    }

    /// Every browser tab, the workspaces no window shows, and each renderer's frames.
    public struct Snapshot: Sendable, Equatable {
        public var tabs: [Tab]
        public var hiddenWorkspaces: Set<String>
        /// Every frame each renderer hosts, by pid, over every browser of the engine (popups, spares and
        /// DevTools too, which ``tabs`` does not list): the denominator a shared renderer is split by. A renderer
        /// left out is one whose frames are unknown.
        public var rendererFrames: [Int32: Int]

        public init(tabs: [Tab], hiddenWorkspaces: Set<String>, rendererFrames: [Int32: Int]) {
            self.tabs = tabs
            self.hiddenWorkspaces = hiddenWorkspaces
            self.rendererFrames = rendererFrames
        }
    }

    /// What one hidden workspace's sample found.
    public enum Attribution: Sendable, Equatable {
        /// Its renderers' share of memory, in KiB.
        case clear(kibibytes: Int64)
        /// Its memory cannot be told apart; nothing is recorded.
        case unclear(Unclear)
    }

    /// Why a hidden workspace's memory is unclear.
    public enum Unclear: Sendable, Equatable {
        /// A frame of one of its tabs has no renderer with a known pid.
        case unresolvedFrames
        /// A renderer of its tabs has no whole frame count (``Snapshot/rendererFrames``), so its share is unknown.
        case unknownRendererShare
        /// A renderer's footprint could not be read (it ended, or is not ours).
        case unreadableFootprint
    }

    /// The samples recorded and the unclear ones, per trigger, since launch.
    public struct Tally: Sendable, Equatable {
        public var recorded: [Trigger: UInt64]
        public var unclear: [Trigger: UInt64]

        public init(recorded: [Trigger: UInt64] = [:], unclear: [Trigger: UInt64] = [:]) {
            self.recorded = recorded
            self.unclear = unclear
        }
    }

    /// One trigger's counters.
    private final class Counts: Sendable {
        let recorded = Atomic<UInt64>(0)
        let unclear = Atomic<UInt64>(0)
    }

    private let metrics: Metrics
    private let footprint: @Sendable (Int32) -> UInt64?
    /// By ``Trigger/rawValue``.
    private let counts: [Counts] = Trigger.allCases.map { _ in Counts() }

    /// Records into `metrics` (the app runtime's store by default) and reads a pid's physical footprint in bytes
    /// with `footprint` (``physicalFootprint(of:)`` by default; tests pass a fake).
    public init(metrics: Metrics = Metrics(), footprint: @escaping @Sendable (Int32) -> UInt64? = MemorySampler.physicalFootprint(of:)) {
        self.metrics = metrics
        self.footprint = footprint
    }

    /// Attributes and records one sample: `memory.hidden_workspace_kib` once per hidden workspace whose
    /// attribution is clear, and a count per hidden workspace, recorded or unclear, under `trigger`. Reads each
    /// renderer's footprint once: call it off the main thread. Returns each hidden workspace's attribution.
    @discardableResult
    public func sample(_ snapshot: Snapshot, trigger: Trigger) -> [String: Attribution] {
        let attributions = Self.attribute(snapshot, footprint: footprint)
        let counts = counts[trigger.rawValue]
        for attribution in attributions.values {
            switch attribution {
            case let .clear(kibibytes):
                metrics.record(.memoryHiddenWorkspace, kibibytes)
                counts.recorded.wrappingAdd(1, ordering: .relaxed)
            case .unclear:
                counts.unclear.wrappingAdd(1, ordering: .relaxed)
            }
        }
        return attributions
    }

    /// The samples recorded and unclear per trigger since launch (triggers with none are left out).
    public func tally() -> Tally {
        var tally = Tally()
        for trigger in Trigger.allCases {
            let counts = counts[trigger.rawValue]
            let recorded = counts.recorded.load(ordering: .relaxed), unclear = counts.unclear.load(ordering: .relaxed)
            if recorded > 0 { tally.recorded[trigger] = recorded }
            if unclear > 0 { tally.unclear[trigger] = unclear }
        }
        return tally
    }

    /// Each hidden workspace with a browser tab, and the memory its renderers hold for it: each renderer's
    /// footprint (bytes, from `footprint`, read once per renderer) times the share of the renderer's whole frame
    /// count (``Snapshot/rendererFrames``) that the workspace's tabs have. A renderer whose whole count is
    /// missing, or below the frames ``Snapshot/tabs`` puts in it, makes every hidden workspace in it unclear.
    /// O(tabs x renderers per tab).
    public static func attribute(_ snapshot: Snapshot, footprint: (Int32) -> UInt64?) -> [String: Attribution] {
        var listedFrames: [Int32: Int] = [:]
        var hidden: [String: (frames: [Int32: Int], unresolved: Bool)] = [:]
        for tab in snapshot.tabs {
            for share in tab.renderers where share.frames > 0 { listedFrames[share.pid, default: 0] += share.frames }
            guard let workspace = tab.workspace, snapshot.hiddenWorkspaces.contains(workspace) else { continue }
            var entry = hidden[workspace] ?? (frames: [:], unresolved: false)
            for share in tab.renderers where share.frames > 0 { entry.frames[share.pid, default: 0] += share.frames }
            entry.unresolved = entry.unresolved || tab.hasUnresolvedFrames
            hidden[workspace] = entry
        }
        var footprints: [Int32: UInt64?] = [:]
        func kibibytes(of pid: Int32) -> UInt64? {
            if let known = footprints[pid] { return known }
            let read = footprint(pid).map { $0 / 1_024 }
            footprints[pid] = read
            return read
        }
        var attributions: [String: Attribution] = [:]
        for (workspace, entry) in hidden {
            guard !entry.unresolved else {
                attributions[workspace] = .unclear(.unresolvedFrames)
                continue
            }
            let whole = entry.frames.keys.map { (pid: $0, all: snapshot.rendererFrames[$0] ?? 0) }
            guard whole.allSatisfy({ $0.all >= listedFrames[$0.pid, default: 0] }) else {
                attributions[workspace] = .unclear(.unknownRendererShare)
                continue
            }
            var total: Int64 = 0, readable = true
            for (pid, all) in whole {
                guard let size = kibibytes(of: pid), let frames = entry.frames[pid] else {
                    readable = false
                    break
                }
                total += Int64(clamping: size) * Int64(frames) / Int64(all)
            }
            attributions[workspace] = readable ? .clear(kibibytes: total) : .unclear(.unreadableFootprint)
        }
        return attributions
    }

    /// `pid`'s physical footprint in bytes (`proc_pid_rusage`'s `ri_phys_footprint`, what Activity Monitor shows
    /// as Memory and Chrome reports as a process's private memory footprint); nil when it ended or is not ours.
    /// One system call: call it off the main thread.
    public static func physicalFootprint(of pid: Int32) -> UInt64? {
        var info = rusage_info_v0()
        // SAFETY: the pointer is `info`'s, valid for the call; proc_pid_rusage writes one rusage_info_v0
        // (RUSAGE_INFO_V0) through it, which is what `info` is.
        let status = unsafe withUnsafeMutablePointer(to: &info) { pointer in
            unsafe pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                unsafe blockingProcPidRusage(pid, RUSAGE_INFO_V0, $0)
            }
        }
        return status == 0 ? info.ri_phys_footprint : nil
    }
}

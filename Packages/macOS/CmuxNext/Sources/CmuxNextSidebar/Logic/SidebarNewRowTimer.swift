public import AppKit
public import CmuxNextDesign
import CmuxNextSignposts
import CmuxNextTrace
import QuartzCore

/// A new workspace, from the press to the commit that first draws its sidebar row, in two forms:
///
/// - `create.workspace` (``SignpostName/createWorkspace``), in every build: an async pair (AB/AE) on the
///   trace ring under the `create` category, from the press (else the create) to the Core Animation commit
///   that carries the row (``CommitBoundary``). Chrome traces a navigation the same way, an async
///   `TRACE_EVENT_NESTABLE_ASYNC_BEGIN` keyed by its id that ends in a later task
///   (base/trace_event/typed_macros.h, content/browser/renderer_host/navigation_request.cc).
///   Begin arg0 is ``Origin``, end arg0 is ``Outcome``.
/// - `debug.new_workspace` (``timer``), while its socket method records: `pressed` to `drew` as
///   `SwitchFrameTimer` times a tab switch (`apply_ms`, `commit_ms`, `late_vsyncs`), and `walks`: the rows
///   passes that walked every workspace (`SidebarRowFeed.fill`) between the two. A new workspace's row is
///   drawn from the press, before the daemon creates it (the App's PendingWorkspaceRows), so it needs no
///   walk: perf-gate.py's new_workspaces scenario gates `walks` 0 for every create.
///
/// Off (the `create` category off and not recording), each call is one relaxed load and returns.
@MainActor
public final class SidebarNewRowTimer {
    public static let shared = SidebarNewRowTimer()

    /// Where a `create.workspace` pair began (its begin arg0).
    enum Origin: UInt64 {
        /// The New Workspace action's press.
        case press = 0
        /// The create itself, with no press in its turn (a restore, a script's spawn).
        case create = 1
    }

    /// How a `create.workspace` pair ended (its end arg0).
    enum Outcome: UInt64 {
        /// The commit that carries the row ran.
        case drawn = 0
        /// The create failed or a close took it before its row was drawn.
        case removed = 1
        /// The press's turn ended with no create that lists a row (no window to list it, no daemon).
        case noRow = 2
        /// The boundary saw the run loop wake first (``CommitBoundary/Outcome/missed``): the time includes
        /// idle time, so readers drop it.
        case missed = 3
        /// More than ``openLimit`` creates waited for their row (sidebars that never drew): the oldest ends.
        case dropped = 4
    }

    /// The ring points of `create.workspace`: the process's runtime, or a test's recorder.
    struct Trace {
        /// Whether the `create` category records now (one relaxed load).
        let isEnabled: @MainActor () -> Bool
        /// Writes the pair's AB: async id, ``Origin``.
        let begin: @MainActor (_ id: UInt64, _ origin: UInt64) -> Void
        /// Writes the pair's AE: async id, ``Outcome``.
        let end: @MainActor (_ id: UInt64, _ outcome: UInt64) -> Void

        static func runtime(_ runtime: TraceRuntime) -> Trace {
            let bit = SignpostName.createWorkspace.traceCategory.traceBit
            return Trace(isEnabled: { runtime.isEnabled(categoryBit: bit) },
                         begin: { runtime.asyncBegin(.createWorkspace, id: $0, arg0: $1) },
                         end: { runtime.asyncEnd(.createWorkspace, id: $0, arg0: $1) })
        }
    }

    /// A press whose create has not named its workspace yet.
    private struct Press {
        let time: CFTimeInterval
        let traceID: UInt64?
    }

    /// A create whose row has not been drawn yet.
    private struct Waiting {
        let order: UInt64
        let traceID: UInt64?
        /// The rebuild count at the press, when ``timer`` times this create.
        let walks: Int?
    }

    /// Its socket method reads and starts or stops this (the App's `debug.new_workspace`).
    public let timer = SwitchFrameTimer(owner: "debug.new_workspace")
    /// The most creates that wait for their row at once; past it the oldest ends ``Outcome/dropped``.
    static let openLimit = 64

    private let trace: Trace
    private let afterCommit: @MainActor (@escaping @MainActor (CommitBoundary.Outcome) -> Void) -> Void
    /// This turn's presses whose create has not named its workspace yet, oldest first (creates run in
    /// press order, in the press's turn; the turn's commit ends the rest ``Outcome/noRow``).
    private var presses: [Press] = []
    /// The creates whose row has not been drawn, by workspace id.
    private var waiting: [String: Waiting] = [:]
    private var lastOrder: UInt64 = 0

    convenience init() {
        self.init(trace: .runtime(.shared)) { CommitBoundary().after($0) }
    }

    /// - Parameters:
    ///   - trace: Where the `create.workspace` pairs go.
    ///   - afterCommit: Runs its body after the Core Animation commit that ends this turn (``CommitBoundary``).
    init(trace: Trace, afterCommit: @escaping @MainActor (@escaping @MainActor (CommitBoundary.Outcome) -> Void) -> Void) {
        self.trace = trace
        self.afterCommit = afterCommit
    }

    /// A person or script asked for a new workspace (the App's `newTab` action), now.
    public func pressed() {
        let traced = trace.isEnabled()
        guard traced || timer.isRecording else { return }
        let id = traced ? nextOrder() : nil
        if let id { trace.begin(id, Origin.press.rawValue) }
        if presses.isEmpty { afterCommit { [weak self] _ in self?.endPresses() } }
        presses.append(Press(time: CACurrentMediaTime(), traceID: id))
    }

    /// The create of the oldest press (else one with no press, from now) is workspace `id`.
    public func began(_ id: String) {
        let press = presses.isEmpty ? nil : presses.removeFirst()
        var traceID = press?.traceID
        if press == nil, trace.isEnabled() {
            let started = nextOrder()
            trace.begin(started, Origin.create.rawValue)
            traceID = started
        }
        let timed = timer.isRecording
        guard traceID != nil || timed else { return }
        if timed { timer.began(id, at: press?.time ?? CACurrentMediaTime()) }
        if let replaced = waiting.removeValue(forKey: id) { end(replaced, .dropped) }
        if waiting.count >= Self.openLimit, let oldest = waiting.min(by: { $0.value.order < $1.value.order }) {
            waiting[oldest.key] = nil
            timer.forget(oldest.key)
            end(oldest.value, .dropped)
        }
        waiting[id] = Waiting(order: traceID ?? nextOrder(), traceID: traceID, walks: timed ? Self.walks : nil)
    }

    /// The create of workspace `id` failed or a close took it: a row not drawn yet never will be.
    public func removed(_ id: String) {
        guard let entry = waiting.removeValue(forKey: id) else { return }
        timer.forget(id)
        end(entry, .removed)
    }

    /// The list of `window` drew `sections`: a waiting workspace listed there is shown, and its pair ends
    /// after the commit that carries it.
    func drew(_ sections: [SidebarSection], in window: NSWindow?) {
        guard !waiting.isEmpty else { return }
        var drawn: [UInt64] = []
        rows: for section in sections {
            for workspace in section.workspaces {
                let id = workspace.id.rawValue
                guard let entry = waiting.removeValue(forKey: id) else { continue }
                if let walks = entry.walks, timer.isWaiting(id) {
                    timer.shown(id, in: window, extra: ["walks": Double(Self.walks - walks)])
                }
                if let traceID = entry.traceID { drawn.append(traceID) }
                if waiting.isEmpty { break rows }
            }
        }
        guard !drawn.isEmpty else { return }
        let trace = trace
        afterCommit { outcome in
            let ended = outcome == .committed ? Outcome.drawn : .missed
            for id in drawn { trace.end(id, ended.rawValue) }
        }
    }

    /// The press's turn committed: a press no create took lists no row.
    private func endPresses() {
        for press in presses {
            if let id = press.traceID { trace.end(id, Outcome.noRow.rawValue) }
        }
        presses = []
    }

    private func end(_ entry: Waiting, _ outcome: Outcome) {
        if let id = entry.traceID { trace.end(id, outcome.rawValue) }
    }

    private func nextOrder() -> UInt64 {
        lastOrder &+= 1
        return lastOrder
    }

    private static var walks: Int { SidebarPerfCounters.count(.rebuilds) }
}

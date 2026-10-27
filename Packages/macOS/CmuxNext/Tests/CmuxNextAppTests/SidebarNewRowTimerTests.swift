import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// `create.workspace` (p09-observability task 031): one async pair per new workspace with a row, begun when its
/// create names it (with the press's own input age), ended at the commit boundary after the list reload that first
/// lists its row (any reload: a held change released, an unrelated reload, a space switch); a row that goes before
/// it was drawn, or that no list drew in time, ends the pair as missed. The boundary and the clock are seams the
/// test drives, and each test records into its own ``TraceRuntime``.
@MainActor
@Suite(.serialized) struct SidebarNewRowTimerTests {
    /// The `create.workspace` records a test runtime writes, in order.
    private final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])
        var records: [TraceRuntime.StubRecord] {
            state.withLock { $0 }.filter { $0.name == SignpostName.createWorkspace.rawValue }
        }

        /// A runtime that records into this log, with the create category on.
        func runtime() -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(1 << UInt64(SignpostCategory.create.traceBit))
            return runtime
        }

        /// Each begin's arg0 and its end's code (nil while open), matched by async id, in begin order.
        var pairs: [(begin: UInt64, end: UInt64?)] {
            var result: [(id: UInt64, begin: UInt64, end: UInt64?)] = []
            for record in records {
                switch record.phase {
                case .asyncBegin: result.append((record.arg1, record.arg0, nil))
                case .asyncEnd:
                    if let index = result.firstIndex(where: { $0.id == record.arg1 && $0.end == nil }) {
                        result[index].end = record.arg0 & 0xFF
                    } else {
                        Issue.record("a create.workspace end without its begin")
                    }
                default: Issue.record("create.workspace wrote phase \(record.phase)")
                }
            }
            return result.map { ($0.begin, $0.end) }
        }
    }

    /// Commit boundaries asked for and not fired yet.
    @MainActor
    private final class Boundaries {
        var waiting: [@MainActor (CommitBoundary.Outcome) -> Void] = []
        func fire(_ outcome: CommitBoundary.Outcome = .committed) {
            let due = waiting
            waiting = []
            for body in due { body(outcome) }
        }
    }

    /// The timer's uptime clock (seconds; powers of two keep the ages exact).
    @MainActor
    private final class Uptime {
        var now: TimeInterval = 1_024
    }

    private let log = RecordLog()
    private let boundaries = Boundaries()
    private let clock = Uptime()

    private func makeTimer() -> SidebarNewRowTimer {
        let signposter = Signposter(category: .create, mirror: SignpostMetricKitMirror(), trace: log.runtime())
        let boundaries = boundaries, clock = clock
        return SidebarNewRowTimer(signposter: signposter, boundary: { boundaries.waiting.append($0) }, now: { clock.now })
    }

    /// A list reload in no window that lists `ids`.
    private func draw(_ timer: SidebarNewRowTimer, _ ids: String...) {
        timer.drew(in: nil) { ids.contains($0.rawValue) }
    }

    // MARK: The timer

    @Test("A create is one pair: begun with its press's input age, ended at the commit after its row was listed")
    func drawnRowEndsAtCommit() throws {
        let timer = makeTimer()
        timer.began("w1", inputTimestamp: clock.now - 1.0 / 256) // 3.90625 ms before the begin
        #expect(log.pairs.count == 1)
        draw(timer, "w0") // another row: nothing ends
        #expect(boundaries.waiting.isEmpty)
        draw(timer, "w0", "w1")
        #expect(log.pairs.first?.end == nil, "it ends at the commit, not at the draw")
        boundaries.fire()
        let pair = try #require(log.pairs.first)
        #expect(log.pairs.count == 1)
        #expect(pair.begin >> 40 == 3_906)
        #expect(pair.end == Signposter.EndCode.ended)
        #expect(timer.openCount == 0)
    }

    @Test("A create with no press stamp (a script's, a later task's) writes all ones in the age bits")
    func noInputEvent() {
        let timer = makeTimer()
        timer.began("w1", inputTimestamp: nil)
        timer.began("w2", inputTimestamp: clock.now + 1) // a stamp from after the begin is no input of this create
        #expect(log.pairs.map(\.begin) == [0xFF_FFFF << 40, 0xFF_FFFF << 40])
    }

    @Test("A second listing of the row in the same turn asks for one boundary; later listings end nothing")
    func oneEndPerCreate() {
        let timer = makeTimer()
        timer.began("w1", inputTimestamp: nil)
        draw(timer, "w1")
        draw(timer, "w1")
        #expect(boundaries.waiting.count == 1)
        boundaries.fire()
        draw(timer, "w1")
        #expect(boundaries.waiting.isEmpty)
        #expect(log.pairs.count == 1)
        #expect(log.pairs.first?.end == Signposter.EndCode.ended)
    }

    @Test("A row that goes before it was drawn (failed create, close) ends missed; a listed row's forget changes nothing")
    func forgetEndsMissed() {
        let timer = makeTimer()
        timer.began("gone", inputTimestamp: nil)
        timer.forget("gone")
        #expect(log.pairs.map(\.end) == [Signposter.EndCode.missed])
        timer.began("drawn", inputTimestamp: nil)
        draw(timer, "drawn")
        timer.forget("drawn")
        boundaries.fire()
        #expect(log.pairs.map(\.end) == [Signposter.EndCode.missed, Signposter.EndCode.ended])
        #expect(timer.openCount == 0)
    }

    @Test("A boundary that missed the commit ends the pair as missed")
    func missedBoundary() {
        let timer = makeTimer()
        timer.began("w1", inputTimestamp: nil)
        draw(timer, "w1")
        boundaries.fire(.missed)
        #expect(log.pairs.map(\.end) == [Signposter.EndCode.missed])
    }

    @Test("A create no list drew in time ends missed, so a late listing never records a long committed sample")
    func staleCreateEndsMissed() {
        let timer = makeTimer()
        timer.began("late", inputTimestamp: nil)
        clock.now += SidebarNewRowTimer.staleAfter + 1
        draw(timer, "late")
        #expect(boundaries.waiting.isEmpty, "a late listing asked for a boundary")
        #expect(log.pairs.map(\.end) == [Signposter.EndCode.missed])
        #expect(timer.openCount == 0)
    }

    @Test("Creates past the open limit end the oldest as missed")
    func openLimit() {
        let timer = makeTimer()
        for index in 0...SidebarNewRowTimer.openLimit { timer.began("w\(index)", inputTimestamp: nil) }
        #expect(timer.openCount == SidebarNewRowTimer.openLimit)
        #expect(log.pairs.first?.end == Signposter.EndCode.missed)
        #expect(log.pairs.dropFirst().allSatisfy { $0.end == nil })
    }

    @Test("Interleaved creates end each at its own row's commit")
    func interleaved() {
        let timer = makeTimer()
        timer.began("a", inputTimestamp: nil)
        timer.began("b", inputTimestamp: nil)
        draw(timer, "b")
        boundaries.fire()
        #expect(log.pairs.map(\.end) == [nil, Signposter.EndCode.ended])
        draw(timer, "a", "b")
        boundaries.fire()
        #expect(log.pairs.map(\.end) == [Signposter.EndCode.ended, Signposter.EndCode.ended])
    }

    // MARK: PendingWorkspaceRows

    private func row(_ id: String, window: String) -> PendingWorkspaceRows.Row {
        let machine = CmuxNextSidebar.MachineID.local
        return .init(id: id, window: window, machine: machine,
                     face: SidebarMapping.shared.creatingRow(id: id, machine: machine, name: "workspace-1", opensPage: true),
                     slot: nil, byDefault: nil)
    }

    @Test("A pending row begins its pair with the press's stamp; removing it before it was drawn ends the pair missed")
    func pendingRowRemovedBeforeDrawEndsMissed() {
        let rows = PendingWorkspaceRows(newRows: makeTimer())
        rows.add(row("ws-1", window: "w1"), name: "workspace-1", inputTimestamp: clock.now - 1.0 / 512) // 1.953125 ms
        #expect(log.pairs.map(\.begin) == [1_953 << 40])
        rows.remove("ws-1")
        #expect(log.pairs.map(\.end) == [Signposter.EndCode.missed])
        #expect(rows.newRows.openCount == 0)
    }

    @Test("A pending row that leaves its window unlisted ends missed; one its window lists ends at the list's draw")
    func pendingRowForgottenUnlistedEndsMissed() {
        let rows = PendingWorkspaceRows(newRows: makeTimer())
        rows.add(row("elsewhere", window: "w1"), name: "workspace-1")
        rows.add(row("listed", window: "w1"), name: "workspace-2")
        rows.forget(in: "w1", listed: ["listed"], held: { _ in true }, elsewhere: { $0 == "elsewhere" })
        #expect(log.pairs.map(\.end) == [Signposter.EndCode.missed, nil])
        draw(rows.newRows, "elsewhere", "listed") // a late listing of the missed one ends nothing more
        boundaries.fire()
        #expect(log.pairs.map(\.end) == [Signposter.EndCode.missed, Signposter.EndCode.ended])
    }

    // MARK: The sidebar list

    /// The local machine's section with the workspaces `ids`, in that order.
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    /// A sidebar in an off-screen window whose list reports to `timer`, with workspaces 1-3 drawn and the pointer
    /// over its rows; a script then adds workspace 4 (not this user's change, so it waits under the pointer).
    private func sidebarHoldingANewRow(_ timer: SidebarNewRowTimer) throws
        -> (sidebar: SidebarView, window: NSWindow, held: CmuxNextSidebar.WorkspaceID) {
        let model = SidebarModel(sections: Self.sections([1, 2, 3]))
        let sidebar = SidebarView(model: model, design: DesignSettings(), newRows: timer)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        sidebar.list.reload(animated: false, fromModel: true)
        sidebar.list.pointerIsOverList = { _ in true }
        let next = Self.sections([1, 2, 3, 4])
        let held = try #require(next.first?.workspaces.last?.id)
        timer.began(held.rawValue, inputTimestamp: nil)
        model.sections = next
        sidebar.renderNow()
        #expect(sidebar.list.workspaces[held] == nil, "the script's row did not wait under the pointer")
        #expect(boundaries.waiting.isEmpty, "a held row ended its pair")
        return (sidebar, window, held)
    }

    @Test("A held new row ends its pair at the boundary of the reload that releases it")
    func heldRowEndsWhenReleased() throws {
        let (sidebar, window, held) = try sidebarHoldingANewRow(makeTimer())
        defer { window.close() }
        sidebar.list.pointerIsOverList = { _ in false }
        sidebar.list.releaseHeldModelChange()
        #expect(sidebar.list.workspaces[held] != nil)
        #expect(boundaries.waiting.count == 1)
        boundaries.fire()
        #expect(log.pairs.map(\.end) == [Signposter.EndCode.ended])
    }

    @Test("A held new row shown by any other reload (a drop's end, a space switch) ends its pair there")
    func heldRowEndsAtAnyReload() throws {
        let (sidebar, window, held) = try sidebarHoldingANewRow(makeTimer())
        defer { window.close() }
        sidebar.list.reload(animated: false) // not the release path: the reload itself reports the rows it lists
        #expect(sidebar.list.workspaces[held] != nil)
        #expect(boundaries.waiting.count == 1)
        boundaries.fire()
        #expect(log.pairs.map(\.end) == [Signposter.EndCode.ended])
        sidebar.list.releaseHeldModelChange()
        #expect(boundaries.waiting.isEmpty, "the pair ended twice")
    }
}

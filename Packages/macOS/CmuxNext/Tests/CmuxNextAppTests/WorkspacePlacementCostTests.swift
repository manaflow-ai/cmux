import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextLayout
@testable import CmuxNextSidebar
import Foundation
import Testing

/// WORKSPACE LIST 800 (SESSION 800, 2026-11-10): in the person's session (826 workspaces) each new workspace blocked
/// the main thread two times for about 110 ms; at 60 workspaces nothing blocked. One sample of 20 new workspaces at
/// 826 had 76 samples in `WindowManager.applyPendingPlacements`, 53 of them in `SidebarBridge.place`: after the
/// document took the move, `resync()` mapped EVERY row of the window from its store again, with no row feed.
///
/// The test applies ONE pending placement (a new workspace right below the fifth row) on an active in-process sidebar
/// document, in a whole window of the `LargeSessionWindowFixture` session, and counts what that one
/// `applyPendingPlacements` call did:
///
/// - `rows_made`: rows mapped from their stores, with or without a feed (`SidebarRowFeed.Make.rows`).
/// - `slot_rows`: rows the slot rule's placeholder filter walked and copied (`SidebarSection.withoutPlaceholders`).
/// - `doc_reshows`: `SidebarDocStore.reshow` calls (each reads every live workspace's ref).
/// - `project`: whole-document projections in the Rust mirror (`SidebarMirror.calls["project"]`).
/// - `row_maps`, `rebuilds`, `section_sets`, `ffi_calls`: printed for each size, not checked here.
///
/// NEW WORKSPACE 800 (2026-11-10): the placement is the last part of the turn that the daemon's event starts
/// (`WindowManager.reconcileMembership`): at 826 that ONE turn held the main thread 40 ms (5 ms at 60), and each new
/// workspace had a stall of 50 ms or more in 8 to 11 of 20 runs (0 of 20 at 60). The same fixture counts what the
/// membership part of that turn did for the one new workspace (`WindowRegistryStore.membershipWork`):
///
/// - `answer_writes`: observed per-workspace entries the registry store wrote (window kind, owner).
/// - `order_builds`: builds of a daemon's workspace order in one membership turn.
///
/// It first REQUIRES that the path under test ran: the pending placement is gone, the document places the new
/// workspace right below its anchor and the window's rows list it there. Sizes: `large` (60) always, and each other
/// size `CMUX_TEST_SESSION_SIZES` names (826 runs on a mini, never by default: `SessionFixtureSize`). Each checked
/// count has a bound with no session size in it and may not be larger at a larger size than at `large`.
///
///     CMUX_TEST_SESSION_SIZES=large,real swift test --filter WorkspacePlacementCostTests
@MainActor @Suite(.serialized) struct WorkspacePlacementCostTests {
    typealias Fixture = LargeSessionWindowFixture

    static let sizes: [SessionFixtureSize] = [.large] + SessionFixtureSize.arms.filter { $0 != .large }
    static let session = "s-local"
    static let section = "sec_m_s-local"
    /// The new workspace's key and resource id.
    static let newKey = "placement-cost-new"
    /// The most rows one placement may map or copy, at any session size (the `large` session has 60).
    static let rowBound = 128
    /// The most rows one placement may map from their stores: measured 1 (its own row); `resync()` mapped rows + 1.
    static let madeBound = 2
    /// The most observed registry entries one new workspace may write: measured 2 at 60 and at 826 (its window kind and its owner).
    static let answerBound = 4
    static let printed = ["rows_made", "slot_rows", "doc_reshows", "row_maps", "rebuilds", "section_sets", "ffi_calls", "list_reloads", "layout_rows"]

    /// What one `applyPendingPlacements` call did.
    struct Counts: Sendable {
        var sidebar: [String: Int] = [:]
        var projections = 0
        var listed = 0
        /// Observed registry entries written from the daemon's event to the end of the membership turn.
        var answerWrites = 0
        /// Workspace order builds of ONE membership turn, and the daemons it read.
        var orderBuilds = 0
        var daemons = 0

        subscript(name: String) -> Int { sidebar[name] ?? 0 }
    }

    /// One measured window per size, for the whole suite: a window of 826 workspaces takes seconds to open.
    private static var measured: [SessionFixtureSize: Counts] = [:]

    /// A well-formed document order key for position `index` (two base-62 digits, never ending in `0`).
    private static func order(_ index: Int) -> String {
        let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        return String([digits[1 + index / 61], digits[1 + index % 61]])
    }

    /// A sidebar document that places every workspace of the session of `size`, in the fixture's order.
    private static func documentData(_ size: SessionFixtureSize) -> Data {
        let items = (1...size.workspaces).map { workspace -> String in
            let key = Fixture.key(workspace)
            return #"{"id": "w_\#(key)", "section": "\#(section)", "order": "\#(order(workspace - 1))", "body": {"type": "workspace", "ref": {"session_id": "\#(session)", "workspace_id": "\#(key)"}}}"#
        }
        return Data(#"{"revision": "1", "sections": [{"id": "\#(section)", "kind": {"type": "machine", "session_id": "\#(session)"}}], "items": [\#(items.joined(separator: ","))]}"#.utf8)
    }

    /// The fixture's session with a public resource id on each workspace: only such a workspace has a document ref.
    private static func tree(_ size: SessionFixtureSize) -> DaemonTree {
        var tree = Fixture.tree(size)
        for index in tree.workspaces.indices { tree.workspaces[index].resourceID = ResourceID(rawValue: Fixture.key(index + 1)) }
        return tree
    }

    /// A workspace the session does not hold: one screen, one pane, one terminal.
    private static func newWorkspace() -> WorkspaceSnapshot {
        let pane = PaneSnapshot(id: PaneID(rawValue: 900_001), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 900_001), title: "zsh")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 900_001), layout: .leaf(pane.id), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 900_001), key: WorkspaceKey(rawValue: newKey),
                                 resourceID: ResourceID(rawValue: newKey), name: "placement cost", screens: [screen])
    }

    /// The workspace ids `order` lists right after `anchor`.
    private static func next(after anchor: String, in order: [String]) -> String? {
        guard let at = order.firstIndex(of: anchor), order.count > at + 1 else { return nil }
        return order[at + 1]
    }

    /// One new workspace placed right below the fifth row of a window of a session of `size`.
    static func counts(_ size: SessionFixtureSize) async throws -> Counts {
        if let counts = measured[size] { return counts }
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let windows = services.windows
        windows.ordersWindowsIn = false
        // Its first read installs the app's own document store: finish that before this one replaces it.
        _ = services.sidebarLayout
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree(size))
        let document = SidebarDocStore(remote: SidebarGroupDragRailTests.Remote(document: documentData(size)))
        services.sidebarDoc.store = document
        document.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(20)) { document.isActive }
        try #require(document.isActive, "fixture: the sidebar document did not load")
        document.show(live: services.sidebarDoc.docMachines.liveRefs())
        let keys = [Fixture.key(size.workspaces)] + (1..<size.workspaces).map(Fixture.key)
        let controller = try #require(windows.openWindow(workspaces: keys, frame: CGRect(x: 200, y: 200, width: 1600, height: 900)))
        defer { controller.teardown(); controller.window?.close() }
        for _ in 0..<50 where controller.workspaceContent == nil { await Fixture.drainMain() }
        await Fixture.drainMain()
        document.show(live: services.sidebarDoc.docMachines.liveRefs())
        controller.sidebar.sameTurn.syncNow(rows: true)
        await Fixture.drainMain()
        // The fixture: an active document orders the window's rows, and they list the session.
        let anchor = Fixture.key(5)
        try #require(services.sidebarDoc.isActive && services.sidebarDoc.store === document, "fixture: the document is not the app's active one")
        try #require(controller.sidebar.model.docDrag != nil, "fixture: the window's rows are not on the sidebar document")
        try #require(services.sidebarDoc.item(workspace: anchor) != nil, "fixture: the document does not place the anchor row")
        let listed = controller.sidebar.model.selectableWorkspaces.map(\.id.rawValue)
        try #require(listed.contains(anchor) && listed.count > size.workspaces / 2,
                     "fixture: the window lists \(listed.count) rows of \(size.workspaces)")

        // The daemon's event and the membership it changes, with the placement held: the measured call is the
        // placement alone. No await from here to the last count (an observation hop would run the placement).
        let pendingRows = PendingWorkspaceRows.shared
        try #require(!pendingRows.placing)
        pendingRows.placing = true
        defer { pendingRows.placing = false }
        NewWorkspacePlacements.expect(newKey, in: controller.state.id, slot: .below(anchor), byDefault: nil, windows: windows)
        let entity = newWorkspace()
        _ = windows.registry.takeMembershipWork()
        _ = store.apply(.workspaceAdded(WorkspaceDelta(workspace: entity.id, index: size.workspaces, entity: entity,
                                                      workspaceRevision: store.workspaceRevision + 1)))
        // The event's own turn (the store's workspace-list hook, when a window installed it), then ONE turn alone.
        let eventWork = windows.registry.takeMembershipWork()
        windows.reconcileMembership()
        let turnWork = windows.registry.takeMembershipWork()
        pendingRows.placing = false
        try #require(services.machines.workspace(id: newKey) != nil, "fixture: the event added no workspace")
        try #require(windows.registry.value.owner(of: newKey) == controller.state.id, "fixture: the window does not own the new workspace")
        try #require(windows.pendingPlacements[newKey] != nil, "fixture: the placement ran before the measured call")

        _ = SidebarView.perfCounters(reset: true)
        let projected = SidebarMirror.calls["project"] ?? 0
        windows.applyPendingPlacements(live: [newKey])
        let sidebar = SidebarView.perfCounters(reset: true).filter { !$0.key.contains("@") }
        let projections = (SidebarMirror.calls["project"] ?? 0) - projected

        // The path under test ran: the placement was applied, and the row is at its slot.
        try #require(windows.pendingPlacements[newKey] == nil, "the path under test did not run: the placement is still pending")
        let placed = (document.shown?.machines[session] ?? []).compactMap { node -> String? in
            if case let .workspace(ref, _) = node { return ref.workspaceID }
            return nil
        }
        try #require(next(after: anchor, in: placed) == newKey,
                     "the path under test did not run: the document places \(next(after: anchor, in: placed) ?? "nothing") below the anchor, not the new workspace")
        let rows = controller.sidebar.model.selectableWorkspaces.map(\.id.rawValue)
        try #require(next(after: anchor, in: rows) == newKey,
                     "the path under test did not run: the window lists \(next(after: anchor, in: rows) ?? "nothing") below the anchor, not the new workspace")

        let counts = Counts(sidebar: sidebar, projections: projections, listed: rows.count,
                            answerWrites: eventWork.answerWrites + turnWork.answerWrites,
                            orderBuilds: turnWork.orderBuilds, daemons: services.machines.daemons.count)
        measured[size] = counts
        // Every count, also when the test passes.
        print("WorkspacePlacementCost \(size.rawValue) rows \(rows.count): project \(projections), "
            + printed.map { "\($0) \(counts[$0])" }.joined(separator: ", ")
            + ", answer_writes \(counts.answerWrites), order_builds \(counts.orderBuilds) for \(counts.daemons) daemons")
        return counts
    }

    /// The row maps of one placement: its own row, never every row of the window.
    @Test(.timeLimit(.minutes(10)))
    func onePlacementMapsAsManyRowsInALargerSession() async throws {
        let small = try await Self.counts(.large)
        for size in Self.sizes {
            let counts = try await Self.counts(size)
            #expect(counts["rows_made"] <= Self.madeBound,
                    "one placed workspace in a session of \(size.workspaces) mapped \(counts["rows_made"]) rows from their stores (rows_made, bound \(Self.madeBound))")
            #expect(counts["doc_reshows"] == 1, "one placed workspace in a session of \(size.workspaces) showed the document \(counts["doc_reshows"]) times")
            #expect(counts["rows_made"] <= small["rows_made"],
                    "rows_made grows with the session: \(small["rows_made"]) at large, \(counts["rows_made"]) at \(size.rawValue)")
        }
    }

    /// A RECORD, NOT A GUARD of the placement fix: it passes with and without it (1 projection each). One placement
    /// asks the Rust mirror for at most two whole-document projections, at any size. (Each one still costs more in a
    /// larger session: not changed here.)
    @Test(.timeLimit(.minutes(10)))
    func onePlacementProjectsTheDocumentAsOftenInALargerSession() async throws {
        let small = try await Self.counts(.large)
        for size in Self.sizes {
            let counts = try await Self.counts(size)
            #expect(counts.projections <= 2, "one placed workspace in a session of \(size.workspaces) built \(counts.projections) document projections (bound 2)")
            #expect(counts.projections <= small.projections,
                    "project grows with the session: \(small.projections) at large, \(counts.projections) at \(size.rawValue)")
        }
    }

    /// One new workspace changes ONE workspace's window answers (its kind, its owner): the registry store writes those
    /// observed entries, never one for each workspace a window lists (2 x 827 writes at 826, each one a read through
    /// the observation registrar: 2.5 ms of the turn).
    @Test(.timeLimit(.minutes(10)))
    func oneNewWorkspaceWritesAsManyWindowAnswersInALargerSession() async throws {
        let small = try await Self.counts(.large)
        for size in Self.sizes {
            let counts = try await Self.counts(size)
            #expect(counts.answerWrites >= 1, "the path under test did not run: no window answer was written for the new workspace")
            #expect(counts.answerWrites <= Self.answerBound,
                    "one new workspace in a session of \(size.workspaces) wrote \(counts.answerWrites) observed window answers (answer_writes, bound \(Self.answerBound))")
            #expect(counts.answerWrites <= small.answerWrites,
                    "answer_writes grows with the session: \(small.answerWrites) at large, \(counts.answerWrites) at \(size.rawValue)")
        }
    }

    /// One membership turn builds each daemon's workspace order ONE time (each build reads every workspace and the
    /// document's sections: 2.2 ms at 826), never a second time for the registry's own order.
    @Test(.timeLimit(.minutes(10)))
    func oneMembershipTurnBuildsEachDaemonsOrderOnce() async throws {
        for size in Self.sizes {
            let counts = try await Self.counts(size)
            try #require(counts.daemons >= 1, "fixture: no daemon")
            #expect(counts.orderBuilds == counts.daemons,
                    "one membership turn in a session of \(size.workspaces) built \(counts.orderBuilds) workspace orders for \(counts.daemons) daemons")
        }
    }

    /// NOT FIXED YET: the slot rule copies every row of the window (`WindowManager.placementSections` ->
    /// `SidebarSection.withoutPlaceholders`). The count is here so that its fix has a test; until then a growth is a
    /// known issue (it does not occur at `large` alone).
    @Test(.timeLimit(.minutes(10)))
    func theSlotRuleCopiesAsManyRowsInALargerSession() async throws {
        let small = try await Self.counts(.large)
        for size in Self.sizes {
            let counts = try await Self.counts(size)
            withKnownIssue("the slot rule copies every row: SidebarSection.withoutPlaceholders (WORKSPACE LIST 800, not fixed)", isIntermittent: true) {
                #expect(counts["slot_rows"] <= Self.rowBound,
                        "one placed workspace in a session of \(size.workspaces) copied \(counts["slot_rows"]) rows for its slot (slot_rows, bound \(Self.rowBound))")
                #expect(counts["slot_rows"] <= small["slot_rows"],
                        "slot_rows grows with the session: \(small["slot_rows"]) at large, \(counts["slot_rows"]) at \(size.rawValue)")
            }
        }
    }
}

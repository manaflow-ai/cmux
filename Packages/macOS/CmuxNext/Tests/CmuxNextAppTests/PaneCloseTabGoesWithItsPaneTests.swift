import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Cmd-W on a pane's last tab: the tab and its pane go in one frame.
///
/// What the screen must never show: the closing pane still at its place, with its content, and an empty tab bar
/// (only the new-tab button). A screen recording of the app showed that picture for one or two refreshes, then the
/// picture without the pane.
///
/// The test is the layout's clock (`DisplayLinkDriver.isManual`, 120 Hz steps); the daemon is an offline store. The
/// tab bar follows its model in a job of its own, between the key's turn and the frame tick: the test makes that
/// job's one call (`TabStripView.syncFromModel()`) itself, so it waits for nothing.
@Suite(.closesItsWindows)
@MainActor struct PaneCloseTabGoesWithItsPaneTests {
    typealias Fixture = ClosedPaneContentStaysUntilLandingTests.Fixture

    /// The most frame ticks the test steps before it says that the close never showed.
    static let frames = 8

    /// `moves`: the fixture asks for the panes' move at a close (`PaneCommitMotion`). The closing pane then stays, under
    /// the panes that take its room, to the frame that ends the move: its tab shows in each of those frames too.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aClosingPaneShowsItsLastTabInEachFrameThatShowsThePane(moves: Bool) async throws {
        let app = try await Fixture()
        defer { app.close() }
        if moves { app.root.context.commitMotionOverride = true }
        // The columns that stay share the window after a close: the close changes a pane's size, so it shows at a
        // frame tick and not in the key's own turn.
        app.content.layoutModel.newColumnWidthModeOverride = .fitScreen
        app.content.applyCurrent()
        app.settle()

        let closing = try app.pane(2)
        let strip = closing.view.stripView
        let tabs = closing.stripModel.orderedTabs.map(\.id)
        try #require(tabs.count == 1, "SETUP: the pane has \(tabs.count) tabs, not 1")
        let tab = tabs[0]
        strip.syncFromModel()
        try #require(strip.isShownInWindow, "SETUP: the pane's tab bar does not count as shown in its window")
        try #require(strip.cells[tab] != nil, "SETUP: the tab bar does not show the pane's tab before the close")
        let host = try #require(app.root.context.hosts[closing.layoutPaneID], "SETUP: the pane has no host in the layout")
        try #require(host.superview != nil && !host.isHiddenOrHasHiddenAncestor, "SETUP: the pane does not show before the close")

        // The key's turn, as Cmd-W on the pane's last tab runs it.
        _ = try #require(closing.prepareClose(tabs), "SETUP: the close has no daemon tab")
        try #require(closing.stripModel.tabs.isEmpty, "SETUP: the key's turn left the tab in the tab bar's model")
        try #require(host.superview != nil && !host.isHidden,
                     "SETUP: the key's own turn hid the pane, so no frame shows the pane after the key")
        try #require(strip.isShownInWindow, "SETUP: after the key's turn the tab bar does not count as shown, so it keeps its tabs by the out-of-sight rule")
        // Between the key's turn and the frame tick: the tab bar follows its model.
        strip.syncFromModel()
        #expect(strip.cells[tab] != nil, "before a frame tick the closing pane still shows, and its tab bar is empty")

        // Each frame tick until the one that hides the pane: while the pane shows, so does its tab.
        var bare: [Int] = []
        var hidden: Int?
        // A close's move is over in 0.08 s (10 frames): the frame that ends it hides the pane.
        let most = moves ? Self.frames + 24 : Self.frames
        for frame in 1...most {
            _ = app.root.advanceFrame(ClosedPaneContentStaysUntilLandingTests.dt)
            if host.isHidden || host.superview == nil {
                hidden = frame
                break
            }
            strip.syncFromModel()
            if strip.cells[tab] == nil { bare.append(frame) }
        }
        let at = try #require(hidden, "SETUP: no frame of \(most) hid the closing pane")
        #expect(bare.isEmpty, "the closing pane shows with an empty tab bar in the frames \(bare) after the key")
        // Without this the row with the move proves no more than the row without it.
        if moves { #expect(at > 3, "SETUP: the pane hid in frame \(at): no pane moved at this close") }
    }

    /// A move of a pane's last tab into another pane: the tab shows in one tab bar only, the new one.
    ///
    /// The old pane leaves as after a close, but its tab is not gone: the new tab bar shows it. So the old tab bar must
    /// not show it until the frame that hides the old pane, as it shows a closed tab until then.
    ///
    /// The store is offline, so the test makes the move's turn in its three steps, as `TabMoves.move` makes them with a
    /// daemon: the departure, the move's intent in the store, the departure's close of the pane. Then the jobs that
    /// follow a key's turn, each by its one call: the two panes take the store's state, and each tab bar follows its
    /// model.
    @Test(.timeLimit(.minutes(1)))
    func aPanesLastTabMovedToAnotherPaneShowsInOneBarOnly() async throws {
        let app = try await Fixture()
        defer { app.close() }
        app.content.layoutModel.newColumnWidthModeOverride = .fitScreen
        app.content.applyCurrent()
        app.settle()

        let leaving = try app.pane(2), target = try app.pane(1)
        let old = leaving.view.stripView, new = target.view.stripView
        let moved = try #require(leaving.pane.tabs.first, "SETUP: the pane has no tab in the store")
        try #require(leaving.pane.tabs.count == 1, "SETUP: the pane has \(leaving.pane.tabs.count) tabs, not 1")
        let tab = StripTabID(moved.id)
        old.syncFromModel()
        new.syncFromModel()
        try #require(old.isShownInWindow && new.isShownInWindow, "SETUP: a tab bar does not count as shown in its window")
        try #require(old.cells[tab] != nil && new.cells[tab] == nil, "SETUP: before the move the tab is not in the old tab bar only")
        let host = try #require(app.root.context.hosts[leaving.layoutPaneID], "SETUP: the pane has no host in the layout")
        try #require(host.superview != nil && !host.isHiddenOrHasHiddenAncestor, "SETUP: the pane does not show before the move")

        // The move's turn.
        let leave = TabMoves.depart(moved, into: target.pane, from: leaving, services: app.services)
        app.store.intend(.moveTab(surface: moved.surface, toPane: target.pane.handle, index: target.pane.tabs.count), transaction: .generate())
        _ = leave(true) { _ in }
        try #require(app.content.layoutModel.isClosing(leaving.layoutPaneID), "SETUP: the move's turn did not show the old pane's close")
        try #require(host.superview != nil && !host.isHidden, "SETUP: the move's own turn hid the old pane, so no frame shows it after the key")
        try #require(old.isShownInWindow, "SETUP: after the move's turn the old tab bar does not count as shown, so it follows no model change")
        // The jobs that follow the turn.
        leaving.apply(leaving.snapshot())
        target.apply(target.snapshot())
        try #require(leaving.stripModel.tabs.isEmpty, "SETUP: after the move the old tab bar's model has the tab")
        try #require(target.stripModel.tabs.contains { $0.id == tab }, "SETUP: after the move the new tab bar's model does not have the tab")
        old.syncFromModel()
        new.syncFromModel()
        #expect(new.cells[tab] != nil, "after the move's turn the new tab bar does not show the moved tab")
        #expect(old.cells[tab] == nil, "after the move's turn the moved tab shows in two tab bars")

        // Each frame tick until the one that hides the old pane: the tab shows in the new tab bar only.
        var both: [Int] = []
        var hidden: Int?
        for frame in 1...Self.frames {
            _ = app.root.advanceFrame(ClosedPaneContentStaysUntilLandingTests.dt)
            if host.isHidden || host.superview == nil {
                hidden = frame
                break
            }
            old.syncFromModel()
            new.syncFromModel()
            if old.cells[tab] != nil { both.append(frame) }
        }
        _ = try #require(hidden, "SETUP: no frame of \(Self.frames) hid the old pane")
        #expect(both.isEmpty, "the moved tab shows in two tab bars in the frames \(both) after the move")
        new.syncFromModel()
        #expect(new.cells[tab] != nil, "after the frame that hides the old pane the new tab bar does not show the moved tab")
    }

    /// When the tree without the old pane reaches the store, for a move that the daemon reports.
    enum TreeArrival: CaseIterable, Sendable {
        /// After the jobs that follow the daemon's events ran: the client asks for the tree after it applied the events.
        case afterTheJobs
        /// In the same turn as the daemon's events, before a job ran: the hardest order for the tab bar.
        case inTheSameTurn
    }

    /// A move of a pane's last tab that this client did not make (another client of the daemon): the tab shows in one
    /// tab bar only, the new one.
    ///
    /// The move's own code of this client does not run (`TabMoves.depart`): the old tab bar has only the store to
    /// follow, and the pane's state marks a tab that the store holds in another pane as moved away
    /// (`TabStripModel.take(_:movedAway:)`). The daemon reports the move in two parts. First its events: `tree-changed`, the screen's
    /// `layout-changed` and the tab's `tab-changed`, which takes the tab out of the old pane's record while the store
    /// still lists the pane. Then the tree that the client reads again, which takes the pane out. The test applies the
    /// two parts and lets the main actor run the jobs that follow them (the panes' and the tab bars' own
    /// observations); then it makes each tab bar's one call again, so it waits for no time to pass.
    @Test(.timeLimit(.minutes(1)), arguments: TreeArrival.allCases)
    func aPanesLastTabMovedByTheDaemonShowsInOneBarOnly(_ arrival: TreeArrival) async throws {
        let app = try await Fixture()
        defer { app.close() }
        app.content.layoutModel.newColumnWidthModeOverride = .fitScreen
        app.content.applyCurrent()
        app.settle()

        let leaving = try app.pane(2), target = try app.pane(1)
        let old = leaving.view.stripView, new = target.view.stripView
        let moved = try #require(leaving.pane.tabs.first, "SETUP: the pane has no tab in the store")
        try #require(leaving.pane.tabs.count == 1, "SETUP: the pane has \(leaving.pane.tabs.count) tabs, not 1")
        let tab = StripTabID(moved.id)
        old.syncFromModel()
        new.syncFromModel()
        try #require(old.isShownInWindow && new.isShownInWindow, "SETUP: a tab bar does not count as shown in its window")
        try #require(old.cells[tab] != nil && new.cells[tab] == nil, "SETUP: before the move the tab is not in the old tab bar only")
        let host = try #require(app.root.context.hosts[leaving.layoutPaneID], "SETUP: the pane has no host in the layout")
        try #require(host.superview != nil && !host.isHiddenOrHasHiddenAncestor, "SETUP: the pane does not show before the move")
        /// What the old side shows and holds now, for a failure's message.
        func oldSide() -> String {
            "the old tab bar's model has \(leaving.stripModel.tabs.count) tab(s), the old tab bar counts as shown: \(old.isShownInWindow), the old pane leaves: \(host.isLeaving)"
        }

        // Part 1, the daemon's events. The store can not place the layout (it names one pane less than the store
        // lists), so the tab's own event is the one that changes the store.
        let events: [DaemonEvent] = [
            .treeChanged(transaction: nil),
            .layoutChanged(screen: 1, layout: ScreenLayoutDelta(activePane: 1, layout: .leaf(1), columns: Self.columns([1, 3])), transaction: nil),
            .tabChanged(TabDelta(workspace: 1, screen: 1, pane: 1, surface: 2, index: 1, entity: Self.terminal(2))),
        ]
        _ = app.store.apply(batch: events.enumerated().map { DaemonEventEnvelope(sequence: UInt64($0.offset + 1), event: $0.element) })
        try #require(leaving.pane.tabs.isEmpty, "SETUP: the daemon's events left the tab in the old pane's record")
        try #require(target.pane.tabs.contains { $0.id == moved.id }, "SETUP: the daemon's events did not put the tab in the new pane's record")
        if arrival == .afterTheJobs {
            await Self.drainMain()
            old.syncFromModel()
            new.syncFromModel()
            #expect(new.cells[tab] != nil, "after the daemon's events the new tab bar does not show the moved tab")
            #expect(old.cells[tab] == nil, "after the daemon's events the moved tab shows in two tab bars (\(oldSide()))")
        }

        // Part 2, the tree without the old pane.
        app.store.apply(snapshot: Self.treeAfterTheMove())
        await Self.drainMain()
        app.content.applyLayoutIfChanged()
        try #require(app.store.pane(2) == nil, "SETUP: the tree did not take the old pane out of the store")
        old.syncFromModel()
        new.syncFromModel()
        #expect(new.cells[tab] != nil, "after the tree without the old pane the new tab bar does not show the moved tab")
        #expect(old.cells[tab] == nil, "after the tree without the old pane the moved tab shows in two tab bars (\(oldSide()))")

        // Each frame tick until the one that hides the old pane: the tab shows in the new tab bar only.
        var both: [Int] = []
        var hidden: Int? = host.isHidden || host.superview == nil ? 0 : nil
        var frame = 0
        while hidden == nil, frame < Self.frames {
            frame += 1
            _ = app.root.advanceFrame(ClosedPaneContentStaysUntilLandingTests.dt)
            if host.isHidden || host.superview == nil {
                hidden = frame
                break
            }
            old.syncFromModel()
            new.syncFromModel()
            if old.cells[tab] != nil { both.append(frame) }
        }
        _ = try #require(hidden, "SETUP: no frame of \(Self.frames) hid the old pane")
        #expect(both.isEmpty, "the moved tab shows in two tab bars in the frames \(both) after the tree without the old pane")
        new.syncFromModel()
        #expect(new.cells[tab] != nil, "after the frame that hides the old pane the new tab bar does not show the moved tab")
    }

    /// A move by another client out of a pane that keeps other tabs: the tab leaves its old tab bar at once and shows
    /// in one tab bar only, and the tab that stays takes the first place.
    ///
    /// The old pane stays, so no tab bar keeps a tab for a leaving pane here: the row is for the mark. The pane's state
    /// marks the tab as moved away (`TabStripModel.departures`), so the old tab bar drops its cell with no close motion,
    /// as for a move that this client makes. By a read of the daemon's code, the new pane's `tab-changed` is the event
    /// that takes the tab out of its old pane. A window with no screen applies each change of a tab bar at once: there
    /// the test holds the mark, the one tab bar and the places, not the motion.
    @Test(.timeLimit(.minutes(1)))
    func aTabMovedByTheDaemonOutOfAPaneThatKeepsTabsLeavesItsBarAtOnce() async throws {
        let app = try await Fixture()
        defer { app.close() }
        let (tab, stays) = try await Self.addFrontTab(to: app)
        let leaving = try app.pane(2), target = try app.pane(1)
        let old = leaving.view.stripView, new = target.view.stripView
        new.syncFromModel()
        try #require(old.isShownInWindow && new.isShownInWindow, "SETUP: a tab bar does not count as shown in its window")
        try #require(old.cells[tab] != nil && old.cells[stays] != nil && new.cells[tab] == nil,
                     "SETUP: before the move the old tab bar does not show its two tabs, or the new one shows the tab")
        let first = try #require(old.placed[tab]?.x, "SETUP: the tab has no place in the old tab bar")
        let second = try #require(old.placed[stays]?.x, "SETUP: the tab that stays has no place in the old tab bar")
        try #require(second > first + 1, "SETUP: the tab that stays (x \(second)) is not after the tab that moves (x \(first))")

        // The daemon's event; then each pane's job by its one call, in the same turn, before a tab bar follows.
        Self.report([.tabChanged(Self.delta(4, pane: 1, index: 1))], to: app.store, from: 2)
        try #require(leaving.pane.tabs.count == 1 && target.pane.tabs.count == 2, "SETUP: the daemon's event did not move the tab in the store")
        leaving.apply(leaving.snapshot())
        #expect(leaving.stripModel.departures.contains(tab),
                "the old tab bar's model does not mark the moved tab as moved away, so its tab bar closes it as a closed tab")
        target.apply(target.snapshot())
        func holds(_ when: String) {
            #expect(new.cells[tab] != nil, "\(when) the new tab bar does not show the moved tab")
            #expect(old.cells[tab] == nil && !old.dying.contains(tab),
                    "\(when) the old tab bar still shows the moved tab (in its close motion: \(old.dying.contains(tab)))")
            let place = old.placed[stays]?.x
            let atFirst = place.map { abs($0 - first) < 0.5 } ?? false
            #expect(old.cells[stays] != nil && atFirst,
                    "\(when) the tab that stays is not at the first place (x \(String(describing: place)), the first place \(first))")
            #expect(leaving.stripModel.departures.isEmpty, "\(when) the mark outlived the old tab bar's sync")
        }
        old.syncFromModel()
        new.syncFromModel()
        holds("in the event's turn")
        await Self.drainMain()
        old.syncFromModel()
        new.syncFromModel()
        holds("after the jobs")
    }

    /// A tab that another client moves away and back before its old tab bar's next sync (a tab bar out of sight makes
    /// none) is no departure: its mark goes when the tab comes back into the list. So a later close of it is a close
    /// (the tab bar keeps it for a leaving pane, and plays its close motion), not a move.
    @Test(.timeLimit(.minutes(1)))
    func aTabMovedAwayAndBackIsNoDeparture() async throws {
        let app = try await Fixture()
        defer { app.close() }
        let (tab, _) = try await Self.addFrontTab(to: app)
        let pane = try app.pane(2)
        // Away and back, the pane's job after each by its one call; the tab bar makes no sync between.
        Self.report([.tabChanged(Self.delta(4, pane: 1, index: 1))], to: app.store, from: 2)
        pane.apply(pane.snapshot())
        try #require(pane.stripModel.departures.contains(tab), "SETUP: the move away did not mark the tab")
        Self.report([.tabChanged(Self.delta(4, pane: 2, index: 0))], to: app.store, from: 3)
        pane.apply(pane.snapshot())
        try #require(pane.stripModel.tabs.contains { $0.id == tab }, "SETUP: the move back did not put the tab in the tab bar's model")
        #expect(!pane.stripModel.departures.contains(tab), "the tab came back into the list and kept its mark: its next close plays as a move")
        // Its close: no pane holds the tab then, so nothing marks it.
        Self.report([.tabClosed(Self.delta(4, pane: 2, index: nil))], to: app.store, from: 4)
        pane.apply(pane.snapshot())
        try #require(!pane.stripModel.tabs.contains { $0.id == tab }, "SETUP: the close left the tab in the tab bar's model")
        #expect(!pane.stripModel.departures.contains(tab), "the closed tab is marked as moved away")
    }

    /// The close of a mirror in its tab bar is a close, not a move. A mirror is another pane's browser tab that this pane's
    /// tab bar lists too (`TabMirrors`): the close takes it out of this tab bar only, and the other pane holds the tab
    /// before and after. So the mark must not read "another pane holds it" as "moved away" for an item that was never
    /// a tab of this pane's record. The pane has no window here: the test holds the mark, not the motion.
    @Test(.timeLimit(.minutes(1)))
    func aMirrorClosedInItsTabBarIsNoDeparture() async throws {
        let app = try MirrorIncognitoTests.Fixture()
        let own = try #require(app.normalOther.tabs.first, "SETUP: the pane has no tab of its own")
        let page = try #require(app.normalPage.tabs.first, "SETUP: the other pane has no tab")
        let mirrored = await app.services.mirror(tab: page.id, into: app.normalOther.id, select: false)
        try #require(mirrored, "SETUP: the mirror request was refused")
        let pane = try app.controller(of: app.normalOther)
        defer { pane.teardown() }
        let mirror = StripTabID(page.id)
        pane.apply(pane.snapshot())
        try #require(pane.stripModel.orderedTabs.map(\.id) == [StripTabID(own.id), mirror], "SETUP: the tab bar's model does not have the pane's own tab, then the mirror")
        try #require(pane.isMirror(mirror) && pane.stripModel.departures.isEmpty, "SETUP: the item is no mirror, or a mark is there before the close")
        // The close of the mirror, as its close button runs it. No daemon tab closes, so no command comes back.
        let command = pane.prepareClose([mirror]) != nil
        try #require(!command, "SETUP: the close of a mirror made a daemon command")
        try #require(!pane.stripModel.tabs.contains { $0.id == mirror }, "SETUP: the close left the mirror in the tab bar's model")
        try #require(app.normalPage.tabs.contains { $0.id == page.id }, "SETUP: the close took the tab out of its own pane")
        #expect(!pane.stripModel.departures.contains(mirror), "the closed mirror is marked as moved away, so its tab bar drops it with no close motion")
    }

    /// Gives the fixture's pane 2 a second tab, surface 4, in front of its own: the daemon's `tab-added`, then the jobs
    /// that follow it and the tab bar's one call. Returns the new tab's and the pane's own tab's ids in the tab bar.
    private static func addFrontTab(to app: Fixture) async throws -> (front: StripTabID, own: StripTabID) {
        let pane = try app.pane(2)
        let own = try #require(pane.pane.tabs.first, "SETUP: the pane has no tab in the store")
        report([.tabAdded(delta(4, pane: 2, index: 0))], to: app.store, from: 1)
        await drainMain()
        pane.apply(pane.snapshot())
        pane.view.stripView.syncFromModel()
        let front = try #require(app.store.tab(surface: CmuxNextDaemon.SurfaceID(rawValue: 4)), "SETUP: the store has no tab for the new surface")
        let ids = (front: StripTabID(front.id), own: StripTabID(own.id))
        try #require(pane.stripModel.orderedTabs.map(\.id) == [ids.front, ids.own], "SETUP: the tab bar's model does not have the new tab, then the pane's own")
        return ids
    }

    /// Applies `events` to the store as a batch of the daemon whose first event has the sequence `first`.
    private static func report(_ events: [DaemonEvent], to store: DaemonStore, from first: UInt64) {
        _ = store.apply(batch: events.enumerated().map { DaemonEventEnvelope(sequence: first + UInt64($0.offset), event: $0.element) })
    }

    /// The daemon's delta for the terminal tab of `surface` in `pane` of the fixture's screen, at `index`.
    private static func delta(_ surface: UInt64, pane: UInt64, index: Int?) -> TabDelta {
        TabDelta(workspace: 1, screen: 1, pane: CmuxNextDaemon.PaneID(rawValue: pane), surface: CmuxNextDaemon.SurfaceID(rawValue: surface),
                 index: index, entity: terminal(surface))
    }

    /// Lets the main actor run what is queued (the panes' and the tab bars' observations): a fixed number of yields,
    /// no wait for time to pass.
    private static func drainMain() async {
        for _ in 0..<40 { await Task.yield() }
    }

    private static func terminal(_ surface: UInt64) -> TabSnapshot {
        TabSnapshot(surface: CmuxNextDaemon.SurfaceID(rawValue: surface), title: "~")
    }

    /// The fixture's columns, one pane in each, for `panes`.
    private static func columns(_ panes: [UInt64]) -> [ColumnSnapshot] {
        panes.map { ColumnSnapshot(id: CmuxNextDaemon.ColumnID(rawValue: 10 + $0), width: 1.0 / 3, layout: .leaf(CmuxNextDaemon.PaneID(rawValue: $0))) }
    }

    /// The fixture's tree after the move: pane 2 is gone, and its tab is pane 1's second tab.
    private static func treeAfterTheMove() -> DaemonTree {
        let panes = [PaneSnapshot(id: 1, tabs: [terminal(1), terminal(2)]), PaneSnapshot(id: 3, tabs: [terminal(3)])]
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), columns: columns([1, 3]), panes: panes)
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }
}

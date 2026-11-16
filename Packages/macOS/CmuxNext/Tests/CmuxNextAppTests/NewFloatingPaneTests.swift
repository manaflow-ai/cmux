import CmuxNextActions
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import Foundation
import Testing

/// New Floating Pane (`NewFloatingPane`) gives a floating pane or an error that a person sees, never a tiled pane
/// with no error (decision 2026-11-16). The 2 requests are stand-ins: the split puts the new pane into the store as
/// the daemon's layout event does and answers in the shape of the daemon's reply (the new tab's `surface` and the
/// public ids; no numeric pane handle); the float puts the pane into the screen's floating list.
@MainActor struct NewFloatingPaneTests {
    /// One column of the screen, left to right.
    struct Column {
        var panes: [PaneID]
        var dock: DockSnapshot?
    }

    /// The daemon's rule for a split beside a pane of the agent chat dock: it refuses.
    struct DockColumnRefusal: Error {}

    /// One screen in a store, and the 2 requests of the act as stand-ins.
    @MainActor final class Fixture {
        let store = DaemonStore()
        var columns: [Column]
        var floating: [PaneID] = []
        /// Each pane that a split request named.
        var splits: [PaneID] = []
        /// Each pane that a float request named.
        var floats: [PaneID] = []
        /// Each surface that the act asked the focus for.
        var focused: [SurfaceID] = []
        /// The window's focus intent and each request of the act, in the order in which they came.
        var events: [String] = []
        /// The generation of the intent that the window's stand-in starts.
        static let generation: UInt64 = 7
        /// Whether the store gets the split's new pane before the reply comes.
        var storeGetsThePane = true
        /// The handle of the next pane that a split makes; its tab's surface is the handle plus 100.
        private var next: UInt64 = 10

        init(columns: [Column]) {
            self.columns = columns
            publish()
        }

        private static func chain(_ panes: [PaneID], _ direction: SplitDirection) -> LayoutNode {
            guard let first = panes.first else { return .unknown }
            return panes.dropFirst().reduce(LayoutNode.leaf(first)) { tree, pane in
                LayoutNode.split(id: nil, resourceID: nil, direction: direction, ratio: 0.5, a: tree, b: LayoutNode.leaf(pane))
            }
        }

        /// Gives the store the screen as it is now, as one snapshot of the daemon.
        private func publish() {
            let all = columns.flatMap(\.panes)
            let screen = ScreenSnapshot(
                id: 1,
                layout: Self.chain(all, .right),
                columns: columns.enumerated().map { ColumnSnapshot(id: ColumnID(rawValue: UInt64($0.offset) + 1), width: 0.5, layout: Self.chain($0.element.panes, .down), dock: $0.element.dock) },
                panes: all.map { PaneSnapshot(id: $0, tabs: [TabSnapshot(surface: SurfaceID(rawValue: $0.rawValue + 100))]) },
                floating: floating.map { FloatingPaneSnapshot(pane: $0, frame: .init(x: 0.25, y: 0.25, w: 0.5, h: 0.5)) }
            )
            store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        }

        private func split(_ anchor: PaneID) throws -> SurfaceCreated {
            splits.append(anchor)
            events.append("split \(anchor.rawValue)")
            guard let index = columns.firstIndex(where: { $0.panes.contains(anchor) }), columns[index].dock?.role != .agentChat else { throw DockColumnRefusal() }
            let new = PaneID(rawValue: next)
            next += 1
            if storeGetsThePane {
                columns.insert(Column(panes: [new]), at: index + 1)
                publish()
            }
            let reply = #"{"surface":\#(new.rawValue + 100),"terminal_id":"term_new","pane_id":"pane_new","tab_id":"tab_new"}"#
            return try JSONDecoder().decode(SurfaceCreated.self, from: Data(reply.utf8))
        }

        private func float(_ pane: PaneID) {
            floats.append(pane)
            events.append("float \(pane.rawValue)")
            floating.append(pane)
            publish()
        }

        /// Runs the act for the focused pane `pane`. Returns nil when it threw nothing, else the failure that a key
        /// run of the action shows (`ActionRegistry.refuse(failure:)`) and that a caller of the action gets.
        func run(beside pane: PaneID) async -> ActionWorkFailure? {
            // The window's focus as a stand-in. The intent starts here, before the act runs, as `NewFloatingPane.start`
            // starts it in the turn of the person's key.
            let window = NewPaneFocus(begin: { self.events.append("intent"); return Self.generation }) { surface, generation in
                self.focused.append(surface)
                self.events.append("focus \(surface.rawValue) for intent \(generation)")
            }
            return await run(beside: pane, focus: window.started())
        }

        /// Runs the act for the focused pane `pane` with the focus request `focus` of a window whose intent started.
        func run(beside pane: PaneID, focus: @escaping @MainActor (SurfaceID) -> Void) async -> ActionWorkFailure? {
            let act = NewFloatingPane(store: store, split: { try self.split($0) }, float: { self.float($0) }, focus: focus)
            do {
                try await act.run(beside: pane)
                return nil
            } catch {
                return ActionWorkFailure("new-floating-pane", error)
            }
        }

        /// The floating panes of the screen as the store has them, back to front.
        var floatingInStore: [PaneID] { store.screen(1)?.floating.map(\.pane) ?? [] }
    }

    static let agentChatDock = DockSnapshot(edge: .right, mode: .docked, role: .agentChat)

    @Test func aNewFloatingPaneFromATerminalIsInTheStoresFloatingList() async {
        let fixture = Fixture(columns: [Column(panes: [1])])
        let failure = await fixture.run(beside: 1)
        #expect(failure == nil)
        #expect(fixture.splits == [1], "the split goes to the focused pane")
        #expect(fixture.floatingInStore == [10], "the pane that the split made floats")
        // When the focus is on the floating pane, the next split goes to the last tiled pane.
        let second = await fixture.run(beside: 10)
        #expect(second == nil)
        #expect(fixture.splits == [1, 1])
        #expect(fixture.floatingInStore == [10, 11])
    }

    @Test func aNewFloatingPaneFromADockedColumnSplitsATiledPaneOutsideTheDock() async {
        let fixture = Fixture(columns: [Column(panes: [1]), Column(panes: [2]), Column(panes: [3], dock: Self.agentChatDock)])
        let failure = await fixture.run(beside: 3)
        #expect(failure == nil, "the act from the agent chat dock has no error")
        #expect(fixture.splits == [2], "the split goes to the last tiled pane outside each dock")
        #expect(fixture.floatingInStore == [10])
        // A screen whose tiled panes are all in a dock: no request goes, and the notice says why.
        let docked = Fixture(columns: [Column(panes: [3], dock: Self.agentChatDock)])
        let refusal = await docked.run(beside: 3)
        #expect(docked.splits.isEmpty, "no split request goes to the dock")
        #expect(refusal?.notice(title: nil) == FloatingPaneStrings.noTiledPane)
        #expect(refusal?.refusal == .unavailable, "a caller of the action gets the reason")
    }

    /// Float Pane directly after New Floating Pane must go to the new pane, and the person's keys too: the act asks
    /// for the focus on the new pane, as a split does (a display run 2026-11-16: the focus stayed on the old pane).
    @Test func aNewFloatingPaneAsksForTheFocusOnItsPane() async {
        let fixture = Fixture(columns: [Column(panes: [1])])
        let failure = await fixture.run(beside: 1)
        #expect(failure == nil)
        #expect(fixture.floatingInStore == [10])
        #expect(fixture.focused == [110], "one focus request, for the surface of the new pane's tab")
        #expect(fixture.events == ["intent", "split 1", "focus 110 for intent 7", "float 10"],
                "the intent starts before the split; the focus request has that intent's generation and comes before the float")
        // An act that makes no pane asks for no focus.
        let docked = Fixture(columns: [Column(panes: [3], dock: Self.agentChatDock)])
        _ = await docked.run(beside: 3)
        #expect(docked.focused.isEmpty)
    }

    @Test func aSplitReplyWithNoPaneOfTheStoreIsAnErrorThatAPersonSees() async {
        let fixture = Fixture(columns: [Column(panes: [1])])
        fixture.storeGetsThePane = false
        let failure = await fixture.run(beside: 1)
        #expect(fixture.floats.isEmpty)
        #expect(failure?.notice(title: nil) == FloatingPaneStrings.notFloated, "the act never ends with no error and no floating pane")
        #expect(failure?.refusal == .unavailable, "a caller of the action gets the reason")
    }
}

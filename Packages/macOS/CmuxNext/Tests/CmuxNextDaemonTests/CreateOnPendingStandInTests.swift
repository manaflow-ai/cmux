import Foundation
import Testing
@testable import CmuxNextDaemon

/// A create pressed on another create's stand-in while that one is still in flight (review 1 of
/// PL-motion-core): Cmd-D then New Column on its pane, New Column twice, then the first one
/// closed. The second create never sends the stand-in's handle (the daemon refuses it with
/// "unknown pane" and the shown, focused pane goes): at send time it names the first create's
/// daemon pane, waiting for it, or the first create's own anchor once that create was closed or
/// refused (``DaemonStore/daemonTarget(for:)``), and its overlay shows it there too.
///
/// A wait that hangs fails at the suite's time limit; the stages' deadlines lie past it, so a create
/// that waits for a stage's deadline fails too.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct CreateOnPendingStandInTests {
    private static let pane = PaneID(rawValue: 3)
    private static let place = (workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2))

    private static let baseKey = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001")
    private static let base = WorkspaceSnapshot(
        id: WorkspaceHandle(rawValue: 1), key: baseKey, name: "1",
        screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane, layout: .leaf(pane),
                                 panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))])])])

    /// One workspace with one screen and one pane holding one terminal tab.
    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [base]))
        return store
    }

    private static func screen(of store: DaemonStore) throws -> ScreenModel {
        try #require(store.workspace(id: baseKey.rawValue)?.screens.first)
    }

    /// The daemon's `pane-added` of the pane that takes `provisional` over.
    private static func paneAdded(_ handle: PaneID, taking provisional: ProvisionalPane, surface: UInt64,
                                  sequence: UInt64, echoing transaction: ClientTransactionID? = nil) -> DaemonEventEnvelope {
        DaemonEventEnvelope(sequence: sequence, event: .paneAdded(PaneDelta(
            workspace: place.workspace, screen: place.screen, pane: handle, index: 1,
            entity: PaneSnapshot(id: handle, resourceID: ResourceID(rawValue: provisional.paneID),
                                 tabs: [TabSnapshot(surface: SurfaceID(rawValue: surface))]),
            clientTransactionID: transaction)))
    }

    /// Cmd-D, then New Column on the split's stand-in before the daemon made the split: the
    /// column's send waits for the split's daemon pane (its `pane-added`, not its reply) and names
    /// it; through the daemon's layouts of both, both panes stay shown.
    @Test func newColumnOnAPendingSplitNamesItsDaemonPaneAndBothSurvive() async throws {
        let store = Self.store()
        let split = ProvisionalPane()
        let splitTransaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: split), transaction: splitTransaction)
        let column = ProvisionalPane(columnWidth: 0.5, treeWidth: 0.5)
        store.intend(.splitPane(pane: split.handle, direction: .right, ratio: 0.5, provisional: column), transaction: .generate())
        #expect(try Self.screen(of: store).panes.map(\.handle) == [Self.pane, split.handle, column.handle])
        #expect(store.createTarget(for: split.handle) == .pending(splitTransaction))
        #expect(store.createTarget(for: Self.pane) == .pane(Self.pane), "a daemon pane is its own target")

        let target = Task { try await store.daemonTarget(for: split.handle) }
        try await store.waitUntil("the create waits for its stand-in's daemon pane") { store.standInWaiters.count == 1 }

        // The split's pane-added: the column's send goes, naming the daemon's pane.
        let splitPane = PaneID(rawValue: 9)
        _ = store.apply(batch: [Self.paneAdded(splitPane, taking: split, surface: 7, sequence: 1)])
        #expect(try await target.value == splitPane, "the column's send named the stand-in, which the daemon refuses")
        #expect(try Self.screen(of: store).panes.map(\.handle) == [Self.pane, splitPane, column.handle])

        // The daemon's layout of the split, then of the column after it.
        var tree = Self.base
        let splitLayout = LayoutNode.split(id: nil, resourceID: ResourceID(rawValue: split.splitID), direction: .right, ratio: 0.5,
                                           a: .leaf(Self.pane), b: .leaf(splitPane))
        tree.screens[0].layout = splitLayout
        tree.screens[0].panes.append(PaneSnapshot(id: splitPane, resourceID: ResourceID(rawValue: split.paneID),
                                                  tabs: [TabSnapshot(surface: SurfaceID(rawValue: 7))]))
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [tree]))
        var screen = try Self.screen(of: store)
        #expect(screen.panes.map(\.handle) == [Self.pane, splitPane, column.handle], "the column left once the split was placed")
        #expect(screen.columns.map(\.layout.paneIDs) == [[Self.pane, splitPane], [column.handle]])

        let columnPane = PaneID(rawValue: 11)
        tree.screens[0].layout = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: splitLayout, b: .leaf(columnPane))
        tree.screens[0].columns = [ColumnSnapshot(id: ColumnID(rawValue: 1), width: 0.5, layout: splitLayout),
                                   ColumnSnapshot(id: ColumnID(rawValue: 2), width: 0.5, layout: .leaf(columnPane))]
        tree.screens[0].panes.append(PaneSnapshot(id: columnPane, resourceID: ResourceID(rawValue: column.paneID),
                                                  tabs: [TabSnapshot(surface: SurfaceID(rawValue: 12))]))
        store.apply(snapshot: DaemonTree(workspaceRevision: 3, workspaces: [tree]))
        screen = try Self.screen(of: store)
        #expect(screen.panes.map(\.handle) == [Self.pane, splitPane, columnPane])
        #expect(screen.columns.map(\.layout.paneIDs) == [[Self.pane, splitPane], [columnPane]])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// New Column twice, then the first column closed while both are pending: only the first goes.
    /// The second, made from it, moves to the first one's anchor, in the overlay and at send time,
    /// also once the first one's daemon pane arrives (hidden, its close on the way).
    @Test func closingAPendingColumnKeepsTheColumnMadeFromIt() throws {
        let store = Self.store()
        let first = ProvisionalPane(columnWidth: 0.5, treeWidth: 0.5)
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: first), transaction: .generate())
        let second = ProvisionalPane(columnWidth: 0.5)
        store.intend(.splitPane(pane: first.handle, direction: .right, ratio: 0.5, provisional: second), transaction: .generate())
        #expect(store.creations.cancel(pane: first.handle))

        var screen = try Self.screen(of: store)
        #expect(screen.panes.map(\.handle) == [Self.pane, second.handle], "closing the first column took the second with it")
        #expect(screen.columns.map(\.layout.paneIDs) == [[Self.pane], [second.handle]])
        #expect(store.createTarget(for: first.handle) == .pane(Self.pane), "the second column's send names the closed stand-in")

        _ = store.apply(batch: [Self.paneAdded(PaneID(rawValue: 9), taking: first, surface: 7, sequence: 1)])
        screen = try Self.screen(of: store)
        #expect(screen.panes.map(\.handle) == [Self.pane, second.handle], "the closed column's daemon pane showed")
        #expect(screen.columns.last?.layout.paneIDs == [second.handle])
        #expect(store.createTarget(for: first.handle) == .pane(Self.pane), "the second column was built on the closed one's pane")
        #expect(store.mirrorViolations.isEmpty)
    }

    /// The first column refused: the second, made from it, goes to its anchor.
    @Test func aRefusedColumnHandsTheColumnMadeFromItToItsAnchor() throws {
        let store = Self.store()
        let first = ProvisionalPane(columnWidth: 0.5, treeWidth: 0.5)
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: first), transaction: transaction)
        let second = ProvisionalPane(columnWidth: 0.5)
        store.intend(.splitPane(pane: first.handle, direction: .right, ratio: 0.5, provisional: second), transaction: .generate())
        store.rejectIntent(transaction)

        let screen = try Self.screen(of: store)
        #expect(screen.panes.map(\.handle) == [Self.pane, second.handle])
        #expect(store.createTarget(for: first.handle) == .pane(Self.pane))
        #expect(store.mirrorViolations.isEmpty)
    }

    /// New Column, then Split Left on its stand-in right away (review 2 of PL-motion-core): Split
    /// Left is a reply-path create, with no intent in the log that names the stand-in. The
    /// column's reply settles in the same lift that brings its daemon pane: the stand-in stays
    /// known for the waiting split, which names the daemon pane, never `CreateTargetGone`.
    @Test func aReplyPathCreateFindsTheDaemonPaneWhenItsStandInSettlesInTheSameLift() async throws {
        let store = Self.store()
        let column = ProvisionalPane(columnWidth: 0.5, treeWidth: 0.5)
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: column), transaction: transaction)

        // Split Left's send on the stand-in: no intent of its own.
        let target = Task { try await store.daemonTarget(for: column.handle) }
        try await store.waitUntil("the create waits for its stand-in's daemon pane") { store.standInWaiters.count == 1 }

        // The column's reply settles it with the next snapshot, which also brings its pane.
        store.noteSettledAtNextSnapshot(transaction)
        let columnPane = PaneID(rawValue: 9)
        var tree = Self.base
        tree.screens[0].layout = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5,
                                        a: .leaf(Self.pane), b: .leaf(columnPane))
        tree.screens[0].columns = [ColumnSnapshot(id: ColumnID(rawValue: 1), width: 0.5, layout: .leaf(Self.pane)),
                                   ColumnSnapshot(id: ColumnID(rawValue: 2), width: 0.5, layout: .leaf(columnPane))]
        tree.screens[0].panes.append(PaneSnapshot(id: columnPane, resourceID: ResourceID(rawValue: column.paneID),
                                                  tabs: [TabSnapshot(surface: SurfaceID(rawValue: 7))]))
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [tree]))
        #expect(!store.intentLog.contains(transaction), "the column's create did not settle in the snapshot's lift")
        #expect(try await target.value == columnPane, "the split was refused although the column's daemon pane exists")
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A stand-in the store does not know (never intended, or long gone) is refused, never sent.
    @Test func aCreateOnAnUnknownStandInIsRefused() async {
        let store = Self.store()
        let ghost = ProvisionalPane()
        await #expect(throws: CreateTargetGone.self) { try await store.daemonTarget(for: ghost.handle) }
    }

    /// A create waiting for a stand-in's daemon pane ends when the connection is lost: its command was
    /// bound to that connection, and the stand-in's `pane-added` will never come on it. Before, the
    /// wait held until a later snapshot, or for ever.
    @Test func aLostConnectionEndsEveryWait() async throws {
        let store = Self.store()
        let split = ProvisionalPane()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: split), transaction: .generate())
        let target = Task { try await store.daemonTarget(for: split.handle) }
        try await store.waitUntil("the create waits for its stand-in's daemon pane") { store.standInWaiters.count == 1 }
        _ = store.apply(.disconnected(reason: "socket closed"))
        await #expect(throws: CreateTargetGone.self) { try await target.value }
        #expect(store.standInWaiters.isEmpty)
    }

    /// A create waiting on a stand-in whose own create is refused, or closed by the person before
    /// the daemon made it, ends its wait at once and names that create's anchor.
    @Test func aRefusedOrClosedStandInEndsTheWaitAtItsAnchor() async throws {
        let store = Self.store()
        let refused = ProvisionalPane(), closed = ProvisionalPane()
        let refusedTransaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: refused), transaction: refusedTransaction)
        let first = Task { try await store.daemonTarget(for: refused.handle) }
        try await store.waitUntil("the first create waits") { store.standInWaiters.count == 1 }
        store.rejectIntent(refusedTransaction)
        #expect(try await first.value == Self.pane)

        store.intend(.splitPane(pane: Self.pane, direction: .down, ratio: 0.5, provisional: closed), transaction: .generate())
        let second = Task { try await store.daemonTarget(for: closed.handle) }
        try await store.waitUntil("the second create waits") { store.standInWaiters.count == 1 }
        #expect(store.creations.cancel(pane: closed.handle))
        #expect(try await second.value == Self.pane)
        #expect(store.standInWaiters.isEmpty)
    }

    /// The snapshot path: a resync rebuilds the records with a new pane model for the daemon pane
    /// that took the stand-in over; the target resolves by the stand-in's public id, not by a model
    /// held from the press, so it names the daemon's handle.
    @Test func aResyncSnapshotWithANewPaneModelStillNamesTheDaemonPane() async throws {
        let store = Self.store()
        let split = ProvisionalPane()
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: split), transaction: transaction)
        let target = Task { try await store.daemonTarget(for: split.handle) }
        try await store.waitUntil("the create waits for its stand-in's daemon pane") { store.standInWaiters.count == 1 }
        store.noteSettledAtNextSnapshot(transaction)
        let daemonPane = PaneID(rawValue: 11)
        var tree = Self.base
        tree.screens[0].layout = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(Self.pane), b: .leaf(daemonPane))
        tree.screens[0].panes.append(PaneSnapshot(id: daemonPane, resourceID: ResourceID(rawValue: split.paneID),
                                                  tabs: [TabSnapshot(surface: SurfaceID(rawValue: 12))]))
        store.apply(snapshot: DaemonTree(workspaceRevision: 3, workspaces: [tree]))
        #expect(try await target.value == daemonPane)
        #expect(try await store.daemonTarget(for: split.handle) == daemonPane, "a later create on the stand-in")
        #expect(store.standInWaiters.isEmpty)
    }

    /// A script batch's stage holds workspace 1 (a scripted rename there), and the person's split in it
    /// is pending. The split's `pane-added` comes while a create on its stand-in already waits: the
    /// stage commits instead of holding it, so the create names the daemon's pane now, never at the
    /// stage's deadline (input goes before automation).
    @Test func aWaitInAStagedWorkspaceCommitsTheStageWhenItsPaneArrives() async throws {
        let store = Self.store()
        let scope = DaemonCommandScope()
        let stage = store.openStage(for: scope, until: .now + .seconds(600))
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.renameTab(surface: SurfaceID(rawValue: 4), name: "scripted"), transaction: .generate())
        }
        let split = ProvisionalPane()
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: split), transaction: transaction)
        let target = Task { try await store.daemonTarget(for: split.handle) }
        try await store.waitUntil("the create waits for its stand-in's daemon pane") { store.standInWaiters.count == 1 }

        let daemonPane = PaneID(rawValue: 9)
        _ = store.apply(batch: [Self.paneAdded(daemonPane, taking: split, surface: 7, sequence: 1, echoing: transaction)])
        #expect(!stage.stage.isOpen, "the stage kept the pane-added a waiting create needs")
        #expect(try await target.value == daemonPane, "the create waited for the stage's deadline")
        #expect(store.standInWaiters.isEmpty)
        #expect(store.mirrorViolations.isEmpty)
    }

    /// The same, with the split's `pane-added` already held by the stage when the create is pressed: the
    /// create commits the stage first and names the daemon's pane without waiting.
    @Test func aCreateOnAStandInWhosePaneTheStageHoldsCommitsTheStageFirst() async throws {
        let store = Self.store()
        let scope = DaemonCommandScope()
        let stage = store.openStage(for: scope, until: .now + .seconds(600))
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.renameTab(surface: SurfaceID(rawValue: 4), name: "scripted"), transaction: .generate())
        }
        let split = ProvisionalPane()
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: split), transaction: transaction)
        let daemonPane = PaneID(rawValue: 9)
        _ = store.apply(batch: [Self.paneAdded(daemonPane, taking: split, surface: 7, sequence: 1, echoing: transaction)])
        #expect(stage.stage.isOpen, "the stage did not hold the pane-added of the workspace it touches")
        #expect(store.createTarget(for: split.handle) == .pending(transaction))

        #expect(try await store.daemonTarget(for: split.handle) == daemonPane, "the create waited on the stage")
        #expect(!stage.stage.isOpen)
        #expect(store.standInWaiters.isEmpty)
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A reply-path create (Split Left, no intent of its own) pressed on a stand-in whose pane-added
    /// and layout the stage holds, its reply already in: the create commits the stage, the stand-in's
    /// create settles in that commit's lift, and the stand-in stays known for the create, which names
    /// the daemon's pane, never `CreateTargetGone`.
    @Test func aReplyPathCreateKeepsItsStandInThroughTheStageCommitThatSettlesIt() async throws {
        let store = Self.store()
        let scope = DaemonCommandScope()
        let stage = store.openStage(for: scope, until: .now + .seconds(600))
        DaemonCommandScope.$current.withValue(scope) {
            store.intend(.renameTab(surface: SurfaceID(rawValue: 4), name: "scripted"), transaction: .generate())
        }
        let split = ProvisionalPane()
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: split), transaction: transaction)
        let daemonPane = PaneID(rawValue: 9)
        let layout = ScreenLayoutDelta(layout: .split(id: nil, resourceID: ResourceID(rawValue: split.splitID), direction: .right,
                                                      ratio: 0.5, a: .leaf(Self.pane), b: .leaf(daemonPane)))
        _ = store.apply(batch: [
            Self.paneAdded(daemonPane, taking: split, surface: 7, sequence: 1, echoing: transaction),
            DaemonEventEnvelope(sequence: 2, event: .layoutChanged(screen: Self.place.screen, layout: layout, transaction: transaction)),
        ])
        store.noteSettled(transaction, at: 2)
        #expect(stage.stage.isOpen, "the stage did not hold the split's events")
        #expect(store.intentLog.contains(transaction), "the split settled under a stage that holds its events")

        #expect(try await store.daemonTarget(for: split.handle) == daemonPane, "the stand-in was released in the commit's lift")
        #expect(!stage.stage.isOpen)
        #expect(!store.intentLog.contains(transaction), "the split's create did not settle in the commit")
        #expect(store.mirrorViolations.isEmpty)
    }
}

import Foundation
import Observation
import Testing
@testable import CmuxNextDaemon

/// The edges of the hold of a pane's tab list while tab creations wait (`TabOverlayNetPublishTests` has the rule: a
/// batch publishes only its net change to a pane's tab list, one time): 2 panes held in one batch, a batch that a
/// reader starts inside a publication, the answer and the rejection of one creation, a guessed tab, and the group
/// spans at the hold's end.
@MainActor
struct TabOverlayHoldEdgesTests {
    typealias Rows = TabOverlayNetPublishTests
    typealias Ask = (transaction: ClientTransactionID, page: TabSnapshot)

    /// The pane of workspace 1: the second pane whose creations wait.
    static let otherPane = PaneID(rawValue: 200)

    /// Makes `count` creations in `pane`, as a held New Tab key does. Returns them in the order of the keys.
    static func creations(_ count: Int, in pane: PaneID, of store: DaemonStore) -> [Ask] {
        (0..<count).map { _ in
            let ask = (transaction: ClientTransactionID.generate(), page: Rows.page())
            store.intend(.createTab(pane: pane, provisional: ask.page), transaction: ask.transaction)
            return ask
        }
    }

    static func pane(_ key: String, of store: DaemonStore) throws -> PaneModel {
        try #require(store.workspace(id: key)?.screens.first?.panes.first)
    }

    static func standIns(_ pane: PaneModel) -> [ObjectIdentifier] {
        pane.tabs.filter { ProvisionalTab.isProvisional($0.id) }.map(ObjectIdentifier.init)
    }

    /// The daemon's `tab-added` of the tab that `ask` asked for in the shown pane, on `surface`. With `named` it has
    /// the creation's transaction (the answer); without, nothing on the event names its creation (a raw event).
    static func tabAdded(for ask: Ask, surface: SurfaceID, sequence: UInt64, named: Bool) -> DaemonEventEnvelope {
        var entity = TabSnapshot(surface: surface, kind: .conversation)
        entity.conversation = ask.page.conversation
        return DaemonEventEnvelope(sequence: sequence, event: .tabAdded(TabDelta(
            workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 100), pane: Rows.shownPane, surface: surface, index: nil,
            entity: entity, clientTransactionID: named ? ask.transaction : nil)))
    }

    /// Each of 2 panes whose creations wait is held in one batch. A batch about another workspace writes the tab list
    /// of neither, and a batch that adds a tab to one of them writes only that pane's list, one time.
    @Test func twoPanesWhoseCreationsWaitEachPublishOnlyTheirOwnNetChange() throws {
        let store = Rows.store()
        _ = Self.creations(6, in: Rows.shownPane, of: store)
        _ = Self.creations(6, in: Self.otherPane, of: store)
        let first = try Self.pane("k000", of: store)
        let second = try Self.pane("k001", of: store)
        try #require(first.tabs.count == 7 && second.tabs.count == 7, "setup: the panes list \(first.tabs.count) and \(second.tabs.count) tabs, want 7 and 7")
        let records = (first.tabs + second.tabs).map(ObjectIdentifier.init)
        let firstWrites = Rows.Writes()
        let secondWrites = Rows.Writes()
        firstWrites.track(first)
        secondWrites.track(second)

        for index in 2..<Rows.count { _ = store.apply(batch: [Rows.tabOpened(in: index, sequence: UInt64(index))]) }

        #expect(firstWrites.tabs == 0, "batches about other workspaces wrote the first pane's tab list \(firstWrites.tabs) times")
        #expect(secondWrites.tabs == 0, "batches about other workspaces wrote the second pane's tab list \(secondWrites.tabs) times")
        #expect((first.tabs + second.tabs).map(ObjectIdentifier.init) == records, "a stand-in tab got a new record while its creation waited")

        _ = store.apply(batch: [Rows.tabOpened(in: 1, sequence: UInt64(Rows.count))])

        #expect(firstWrites.tabs == 0, "a batch that adds a tab to the second pane wrote the first pane's tab list \(firstWrites.tabs) times")
        #expect(secondWrites.tabs == 1, "a batch that adds one tab to the second pane wrote its tab list \(secondWrites.tabs) times, want 1")
        #expect(second.tabs.count == 8)
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }

    /// Counts each change of a pane's tab list, and runs `inner` one time in the first change's own call: a batch
    /// that starts inside a publication. `innerReading` is the number that `inner` gave back.
    @MainActor final class ReaderThatApplies {
        var tabs = 0
        var inner: (@MainActor () -> Int)?
        var innerReading: Int?

        func track(_ pane: PaneModel) {
            withObservationTracking { _ = pane.tabs } onChange: {
                MainActor.assumeIsolated {
                    self.tabs += 1
                    self.track(pane)
                    if let inner = self.inner {
                        self.inner = nil
                        self.innerReading = inner()
                    }
                }
            }
        }
    }

    /// A reader of the first pane applies one more batch inside the first pane's publication. The second pane is
    /// still held then: the inner batch does not take its hold and does not end it (at the inner batch's end the
    /// second pane has published nothing). Each hold ends one time: each pane publishes the outer batch's tab one
    /// time, and each publishes the next batch again (no hold stays open).
    /// The row reads no mirror report: the inner batch adds its tab inside the outer batch's publication, after the
    /// outer batch counted the confirmed tabs and before its check of that count, so in a Debug build that check
    /// reports a changed count.
    @Test func aBatchThatAReaderStartsInsideAPublicationEndsEachHoldOneTime() throws {
        let store = Rows.store()
        _ = Self.creations(6, in: Rows.shownPane, of: store)
        _ = Self.creations(6, in: Self.otherPane, of: store)
        let first = try Self.pane("k000", of: store)
        let second = try Self.pane("k001", of: store)
        let reader = ReaderThatApplies()
        let secondWrites = Rows.Writes()
        reader.inner = {
            _ = store.apply(batch: [Rows.tabOpened(in: 5, sequence: 3)])
            return secondWrites.tabs
        }
        reader.track(first)
        secondWrites.track(second)

        // The outer batch adds one tab to each of the 2 panes. The first pane's publication runs the inner batch.
        _ = store.apply(batch: [Rows.tabOpened(in: 0, sequence: 1), Rows.tabOpened(in: 1, sequence: 2)])

        #expect(reader.inner == nil, "the first pane's publication did not run: the inner batch did not start")
        #expect(reader.innerReading == 0, "the inner batch ended the second pane's hold: \(reader.innerReading ?? -1) writes of its tab list at the inner batch's end")
        #expect(reader.tabs == 1, "the outer and the inner batch wrote the first pane's tab list \(reader.tabs) times, want 1")
        #expect(secondWrites.tabs == 1, "the outer and the inner batch wrote the second pane's tab list \(secondWrites.tabs) times, want 1")
        #expect(first.tabs.count == 8 && second.tabs.count == 8, "the panes list \(first.tabs.count) and \(second.tabs.count) tabs, want 8 and 8")
        #expect(try Self.pane("k005", of: store).tabs.count == 2, "the inner batch's tab is not in its pane")

        // No hold stays open: the next batch that adds a tab to each pane is published by each, one time.
        _ = store.apply(batch: [Rows.tabOpened(in: 0, sequence: 4), Rows.tabOpened(in: 1, sequence: 5)])

        #expect(reader.tabs == 2, "after the next batch the first pane's tab list was written \(reader.tabs) times, want 2")
        #expect(secondWrites.tabs == 2, "after the next batch the second pane's tab list was written \(secondWrites.tabs) times, want 2")
        #expect(first.tabs.count == 9 && second.tabs.count == 9)
    }

    /// The answer to one creation puts the daemon's tab in its stand-in's place: one write, and each stand-in that
    /// still waits keeps its record. A rejection of another creation takes its stand-in out: one write.
    /// The settlement step between them holds no rule of the hold: the answer names its creation, so the answer's
    /// batch took the creation out of the intent log already. The settlement finds no intent and starts no lift;
    /// the row reads only that it writes nothing.
    @Test func anAnswerItsSettlementAndARejectionEachPublishOnlyTheNetChange() throws {
        let store = Rows.store()
        let asks = Self.creations(Rows.waiting, in: Rows.shownPane, of: store)
        let pane = try Rows.shown(store)
        let before = Self.standIns(pane)
        try #require(before.count == Rows.waiting && pane.tabs.count == 1 + Rows.waiting, "setup: \(before.count) stand-in tabs of \(pane.tabs.count) tabs")
        let writes = Rows.Writes()
        writes.track(pane)
        let surface = SurfaceID(rawValue: 5_001)

        _ = store.apply(batch: [Self.tabAdded(for: asks[0], surface: surface, sequence: 1, named: true)])

        #expect(writes.tabs == 1, "the answer to one creation wrote the pane's tab list \(writes.tabs) times, want 1")
        #expect(pane.tabs.contains { $0.surface == surface }, "the pane does not list the daemon's tab after the answer")
        #expect(pane.tabs.count == 1 + Rows.waiting)
        #expect(Self.standIns(pane) == Array(before.dropFirst()), "a stand-in tab that still waits got a new record at the answer to another creation")

        store.noteSettled(asks[0].transaction, at: 1)

        #expect(writes.tabs == 1, "the settlement of the answered creation wrote the pane's tab list: \(writes.tabs) writes in sum, want 1")
        #expect(Self.standIns(pane) == Array(before.dropFirst()), "a stand-in tab that still waits got a new record at the settlement of another creation")

        store.rejectIntent(asks[3].transaction)

        #expect(writes.tabs == 2, "the rejection of one creation wrote the pane's tab list: \(writes.tabs) writes in sum, want 2")
        #expect(pane.tabs.count == Rows.waiting)
        var left = Array(before.dropFirst())
        left.remove(at: 2)
        #expect(Self.standIns(pane) == left, "the stand-in tabs after the rejection are not the 10 that still wait, each with its record")
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }

    /// The daemon's raw `tab-added` of the tab that the only creation asked for is a guess: the daemon's tab stays
    /// out of sight and the stand-in keeps its place. The pane's only hold is then the hold of the guessed creation.
    /// The guess and each batch about another workspace write nothing to the pane's tab list, and the stand-in keeps
    /// its record.
    @Test func aGuessedTabKeepsThePaneHeldAndItsStandInsRecord() throws {
        let store = Rows.store()
        let asks = Self.creations(1, in: Rows.shownPane, of: store)
        let pane = try Rows.shown(store)
        try #require(pane.tabs.count == 2, "setup: the pane lists \(pane.tabs.count) tabs, want 2")
        let records = pane.tabs.map(ObjectIdentifier.init)
        let writes = Rows.Writes()
        writes.track(pane)
        let surface = SurfaceID(rawValue: 5_001)

        _ = store.apply(batch: [Self.tabAdded(for: asks[0], surface: surface, sequence: 1, named: false)])

        try #require(!pane.tabs.contains { $0.surface == surface }, "setup: the pane shows the daemon's raw tab: the store made no guess")
        #expect(writes.tabs == 0, "the batch of the guess wrote the pane's tab list \(writes.tabs) times")
        #expect(pane.tabs.map(ObjectIdentifier.init) == records, "the stand-in tab got a new record at the guess")

        for index in 1..<Rows.count { _ = store.apply(batch: [Rows.tabOpened(in: index, sequence: UInt64(index + 1))]) }

        #expect(writes.tabs == 0, "\(Rows.count - 1) batches about other workspaces wrote the tab list of the pane with a guessed tab \(writes.tabs) times")
        #expect(pane.tabs.map(ObjectIdentifier.init) == records, "the stand-in tab got a new record while its guessed creation waited")
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }

    /// A tab's group change in a batch does not count the pane's group spans while the pane is held: the hold's end
    /// counts them one time. The daemon puts the pane's own tab in a group while the creations wait.
    @Test func aGroupChangeInAPaneWhoseCreationsWaitCountsTheGroupSpansAtTheHoldsEnd() throws {
        let store = Rows.store()
        let pane = try Rows.withWaitingCreations(store)
        try #require(pane.groupSpans.isEmpty, "setup: the pane has group spans before the batch")
        let group = TabGroupID(rawValue: "g1")
        var grouped = TabSnapshot(surface: SurfaceID(rawValue: 101))
        grouped.tabGroup = group

        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .tabChanged(TabDelta(
            workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 100), pane: Rows.shownPane, surface: SurfaceID(rawValue: 101),
            index: nil, entity: grouped, clientTransactionID: nil)))])

        #expect(pane.tabs.first?.tabGroup == group, "the pane's first tab is not in the group after the batch")
        #expect(pane.groupSpans == [TabGroupSpan(group: group, range: 0..<1)], "the pane's group spans after the batch: \(pane.groupSpans)")
        #expect(pane.tabs.count == 1 + Rows.waiting)
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }
}

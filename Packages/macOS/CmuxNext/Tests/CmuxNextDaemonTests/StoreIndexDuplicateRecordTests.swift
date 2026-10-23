@testable import CmuxNextDaemon
import Foundation
import Testing

/// Two records of one pane, or of one tab, indexed at once: a move's added delta (a pane or a
/// tab moved into a new screen or workspace) carries its own record while the source still
/// lists the old one. The index must keep the durable id pointing at the record still listed
/// when the other goes, and the tab-list digest must move only when the id comes into the
/// tree or leaves it. The owners of per-tab and per-pane state (`InternalPageTabStore`,
/// `GoneTabWatch`, `AgentTabStore`) ask `pane(id:)` and `tab(id:)` whether the tree still
/// lists their pane or tab: a lost key closes the page tabs of a live pane, or releases the
/// terminal of a live tab.
@MainActor
struct StoreIndexDuplicateRecordTests {
    private static let paneHandle = PaneID(rawValue: 7)

    private static func screen(_ handle: UInt64) -> ScreenModel {
        ScreenModel(ScreenSnapshot(id: ScreenID(rawValue: handle), layout: .leaf(paneHandle), panes: []))
    }

    private static func pane(tabs: [TabSnapshot] = []) -> PaneModel {
        PaneModel(PaneSnapshot(id: paneHandle, tabs: tabs))
    }

    @Test func theRecordStillListedKeepsThePaneIDWhenTheOtherGoes() {
        var index = StoreIndex()
        let source = Self.screen(1), target = Self.screen(2)
        let old = Self.pane(), moved = Self.pane()
        #expect(old.id == moved.id)
        index.insert(old, in: source)
        index.insert(moved, in: target)
        // The source screen re-indexed (a screen-changed or layout event) before pane-closed.
        index.insert(old, in: source)
        #expect(index.panesByID[old.id] === old)
        index.remove(old)
        #expect(index.panesByID[old.id] === moved, "the pane the tree still lists lost its id")
        #expect(index.panesByHandle[Self.paneHandle] === moved)
    }

    @Test func theRecordStillListedKeepsTheTabIDWhenTheOtherGoes() throws {
        var index = StoreIndex()
        let tab = TabSnapshot(surface: SurfaceID(rawValue: 9), title: "~")
        let old = Self.pane(tabs: [tab]), moved = Self.pane(tabs: [tab])
        let source = Self.screen(1), target = Self.screen(2)
        index.insert(old, in: source)
        index.insert(moved, in: target)
        index.insert(old, in: source)
        let oldTab = try #require(old.tabs.first), movedTab = try #require(moved.tabs.first)
        index.remove(oldTab)
        #expect(index.tabsByID[movedTab.id] === movedTab, "the tab the tree still lists lost its id")
        #expect(index.tabsBySurface[movedTab.surface] === movedTab)
    }

    @Test func twoRecordsOfOnePaneMoveTheDigestOnceWhenTheIDComesAndOnceWhenItGoes() {
        var index = StoreIndex()
        _ = index.takeTabListChange()
        let first = Self.pane(), second = Self.pane()
        // 0 -> 2 records in one batch: the pane came.
        index.insert(first, in: Self.screen(1))
        index.insert(second, in: Self.screen(2))
        let change1 = index.takeTabListChange()
        #expect(change1, "a pane that came with two records left the tab list unchanged")
        // 2 -> 1: the pane is still listed.
        index.remove(first)
        let change2 = index.takeTabListChange()
        #expect(!change2, "a pane still listed changed the tab list")
        // 1 -> 0: the pane left.
        index.remove(second)
        let change3 = index.takeTabListChange()
        #expect(change3, "a pane that left changed nothing")
    }

    /// A pane moved into a new screen keeps its handle, so both records of its tab hash alike:
    /// folded per record they cancelled, and a tab closed while both were indexed (both records
    /// gone in one batch) left the digest as it was, so no owner of per-tab state heard it go.
    @Test func twoRecordsOfOneTabMoveTheDigestWhenBothGoInOneBatch() throws {
        var index = StoreIndex()
        let tab = TabSnapshot(surface: SurfaceID(rawValue: 9), title: "~")
        let old = Self.pane(tabs: [tab]), moved = Self.pane(tabs: [tab])
        index.insert(old, in: Self.screen(1))
        index.insert(moved, in: Self.screen(2))
        _ = index.takeTabListChange()
        let oldTab = try #require(old.tabs.first), movedTab = try #require(moved.tabs.first)
        index.remove(oldTab)
        index.remove(movedTab)
        let change4 = index.takeTabListChange()
        #expect(change4, "a tab that left with both its records changed nothing")
    }

    /// The same tab in one pane with two records: one going leaves the tab listed, in the same pane.
    @Test func oneOfTwoRecordsOfATabGoingInTheSamePaneLeavesTheDigest() throws {
        var index = StoreIndex()
        let tab = TabSnapshot(surface: SurfaceID(rawValue: 9), title: "~")
        let old = Self.pane(tabs: [tab]), moved = Self.pane(tabs: [tab])
        index.insert(old, in: Self.screen(1))
        index.insert(moved, in: Self.screen(2))
        _ = index.takeTabListChange()
        index.remove(try #require(old.tabs.first))
        let change5 = index.takeTabListChange()
        #expect(!change5, "a tab still listed in a pane of the same handle changed the tab list")
    }

    @Test func aPaneWithNoTabThatLeavesMovesTheDigest() {
        var index = StoreIndex()
        let pane = Self.pane()
        index.insert(pane, in: Self.screen(1))
        _ = index.takeTabListChange()
        // A refresh re-indexes it: nothing changed.
        index.insert(pane, in: Self.screen(1))
        let change6 = index.takeTabListChange()
        #expect(!change6)
        index.remove(pane)
        let change7 = index.takeTabListChange()
        #expect(change7, "a pane with no tab left and the tab list revision stayed")
    }
}

import Foundation
import Testing
@testable import CmuxBrowser

private struct StubSnapshot: BrowserPanelRestoreSnapshot, Equatable {
    let workspaceId: UUID
    let closedAt: Date
    let index: Int

    init(index: Int, workspaceId: UUID = UUID(), closedAt: Date = Date()) {
        self.index = index
        self.workspaceId = workspaceId
        self.closedAt = closedAt
    }
}

@Suite("RecentlyClosedBrowserStack")
struct RecentlyClosedBrowserStackTests {
    @Test func popReturnsEntriesInLIFOOrder() {
        var stack = RecentlyClosedBrowserStack<StubSnapshot>(capacity: 20)
        stack.push(StubSnapshot(index: 1))
        stack.push(StubSnapshot(index: 2))
        stack.push(StubSnapshot(index: 3))

        #expect(stack.pop()?.index == 3)
        #expect(stack.pop()?.index == 2)
        #expect(stack.pop()?.index == 1)
        #expect(stack.pop() == nil)
        #expect(stack.isEmpty)
    }

    @Test func pushDropsOldestEntriesWhenCapacityExceeded() {
        var stack = RecentlyClosedBrowserStack<StubSnapshot>(capacity: 3)
        for index in 1...5 {
            stack.push(StubSnapshot(index: index))
        }

        #expect(stack.pop()?.index == 5)
        #expect(stack.pop()?.index == 4)
        #expect(stack.pop()?.index == 3)
        #expect(stack.pop() == nil)
    }

    @Test func capacityFloorsAtOne() {
        var stack = RecentlyClosedBrowserStack<StubSnapshot>(capacity: 0)
        #expect(stack.capacity == 1)
        stack.push(StubSnapshot(index: 1))
        stack.push(StubSnapshot(index: 2))
        #expect(stack.entries.count == 1)
        #expect(stack.pop()?.index == 2)
    }

    @Test func removeSnapshotsDropsOnlyEntriesForGivenWorkspaceId() {
        let workspaceA = UUID()
        let workspaceB = UUID()
        var stack = RecentlyClosedBrowserStack<StubSnapshot>(capacity: 20)
        stack.push(StubSnapshot(index: 1, workspaceId: workspaceA))
        stack.push(StubSnapshot(index: 2, workspaceId: workspaceB))
        stack.push(StubSnapshot(index: 3, workspaceId: workspaceA))
        stack.push(StubSnapshot(index: 4, workspaceId: workspaceB))

        stack.removeSnapshots(forWorkspaceId: workspaceA)

        #expect(stack.pop()?.index == 4)
        #expect(stack.pop()?.index == 2)
        #expect(stack.pop() == nil)
    }

    @Test func mostRecentClosedAtTracksLastEntry() {
        var stack = RecentlyClosedBrowserStack<StubSnapshot>(capacity: 20)
        #expect(stack.mostRecentClosedAt == nil)
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        stack.push(StubSnapshot(index: 1, closedAt: early))
        stack.push(StubSnapshot(index: 2, closedAt: late))
        #expect(stack.mostRecentClosedAt == late)
        _ = stack.pop()
        #expect(stack.mostRecentClosedAt == early)
    }
}

@Suite("BrowserModel")
@MainActor
struct BrowserModelTests {
    @Test func recordPopRoundTrip() {
        let model = BrowserModel<StubSnapshot>()
        #expect(model.mostRecentClosedBrowserPanelClosedAt == nil)

        let snapshot = StubSnapshot(index: 1, closedAt: Date(timeIntervalSince1970: 42))
        model.recordClosedBrowserPanel(snapshot)
        #expect(model.mostRecentClosedBrowserPanelClosedAt == snapshot.closedAt)
        #expect(model.popMostRecentlyClosedBrowserPanel() == snapshot)
        #expect(model.popMostRecentlyClosedBrowserPanel() == nil)
    }

    @Test func workspaceCloseDropsOnlyThatWorkspacesEntries() {
        let model = BrowserModel<StubSnapshot>()
        let workspaceA = UUID()
        let workspaceB = UUID()
        model.recordClosedBrowserPanel(StubSnapshot(index: 1, workspaceId: workspaceA))
        model.recordClosedBrowserPanel(StubSnapshot(index: 2, workspaceId: workspaceB))

        model.removeClosedBrowserPanels(forWorkspaceId: workspaceA)
        #expect(model.popMostRecentlyClosedBrowserPanel()?.index == 2)
        #expect(model.popMostRecentlyClosedBrowserPanel() == nil)
    }

    @Test func clearEmptiesHistoryButKeepsCapacity() {
        let model = BrowserModel<StubSnapshot>(recentlyClosedCapacity: 2)
        for index in 1...3 {
            model.recordClosedBrowserPanel(StubSnapshot(index: index))
        }
        model.clearRecentlyClosedBrowserPanels()
        #expect(model.mostRecentClosedBrowserPanelClosedAt == nil)
        #expect(model.popMostRecentlyClosedBrowserPanel() == nil)

        // Capacity survives the clear (legacy re-initialized with 20; the
        // model re-initializes with its own configured capacity).
        for index in 1...3 {
            model.recordClosedBrowserPanel(StubSnapshot(index: index))
        }
        #expect(model.popMostRecentlyClosedBrowserPanel()?.index == 3)
        #expect(model.popMostRecentlyClosedBrowserPanel()?.index == 2)
        #expect(model.popMostRecentlyClosedBrowserPanel() == nil)
    }
}

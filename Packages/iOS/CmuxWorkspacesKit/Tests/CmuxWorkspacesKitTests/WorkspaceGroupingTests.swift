import Foundation
import Testing
@testable import CmuxWorkspacesKit

@Suite struct WorkspaceGroupingTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// 2026-10-13 15:00 UTC.
    private var now: Date { Date(timeIntervalSince1970: 1_791_903_600) }
    private var grouping: WorkspaceGrouping { WorkspaceGrouping(now: now, calendar: calendar) }

    private func item(_ id: String, hoursAgo: Double, status: WorkspaceStatus = .idle, pinned: Bool = false, mac: String = "m1") -> WorkspaceItem {
        WorkspaceItem(id: id, name: id, branch: "b-\(id)", macID: mac, lastActivity: now.addingTimeInterval(-hoursAgo * 3600),
                      status: status, isPinned: pinned, tabs: [WorkspaceTab(id: "\(id)-t", kind: .browser, title: "localhost:\(id)")])
    }

    @Test func dateSectionsPutPinnedFirstThenCalendarDays() {
        let sections = grouping.byDate([
            item("old", hoursAgo: 24 * 30), item("week", hoursAgo: 24 * 4), item("yday", hoursAgo: 20),
            item("today", hoursAgo: 1), item("pin", hoursAgo: 24 * 10, pinned: true),
        ])
        #expect(sections.map(\.kind) == [.pinned, .today, .yesterday, .previous7Days, .older])
        #expect(sections.map { $0.items.map(\.id) } == [["pin"], ["today"], ["yday"], ["week"], ["old"]])
    }

    @Test func filtersDropThePinnedSection() {
        let sections = grouping.byDate([item("a", hoursAgo: 1, status: .needsAttention, pinned: true), item("b", hoursAgo: 2)], filter: .needsYou)
        #expect(sections.map(\.kind) == [.today])
        #expect(sections.first?.items.map(\.id) == ["a"])
    }

    @Test func stateSectionsOrderNeedsYouRunningOther() {
        let sections = grouping.byState([
            item("idle", hoursAgo: 1), item("run", hoursAgo: 2, status: .working),
            item("review", hoursAgo: 3, status: .review), item("ask", hoursAgo: 0.1, status: .needsAttention),
        ])
        #expect(sections.map(\.kind) == [.needsYou, .running, .other])
        #expect(sections[0].items.map(\.id) == ["ask", "review"])
    }

    @Test func emptyStateSectionsAreOmitted() {
        #expect(grouping.byState([item("idle", hoursAgo: 1)]).map(\.kind) == [.other])
    }

    @Test func searchMatchesNameBranchMacAndTabTitles() {
        let items = [item("alpha", hoursAgo: 1, mac: "studio"), item("beta", hoursAgo: 2)]
        let macs = [WorkspaceMac(id: "studio", name: "Mac Studio", isOnline: true), WorkspaceMac(id: "m1", name: "Mini", isOnline: true)]
        #expect(grouping.search(items, query: "ALPHA", macs: macs).map(\.id) == ["alpha"])
        #expect(grouping.search(items, query: "b-beta", macs: macs).map(\.id) == ["beta"])
        #expect(grouping.search(items, query: "studio", macs: macs).map(\.id) == ["alpha"])
        #expect(grouping.search(items, query: "localhost", macs: macs).map(\.id) == ["alpha", "beta"])
        #expect(grouping.search(items, query: "  ", macs: macs).map(\.id) == ["alpha", "beta"])
        #expect(grouping.search(items, query: "zzz", macs: macs).isEmpty)
    }

    @Test func shortAge() {
        #expect(grouping.shortAge(now.addingTimeInterval(-30)) == "now")
        #expect(grouping.shortAge(now.addingTimeInterval(-4 * 60)) == "4m")
        #expect(grouping.shortAge(now.addingTimeInterval(-3 * 3600)) == "3h")
        #expect(grouping.shortAge(now.addingTimeInterval(-2 * 86_400)) == "2d")
    }
}

@MainActor
@Suite struct WorkspacesStoreTests {
    @Test func createIsInstantAndRemembersTheMac() {
        let store = WorkspacesStore.sample()
        let count = store.workspaces.count
        let item = store.create(on: "mini", prompt: "  Fix the crash in tab restore  ")
        #expect(store.workspaces.count == count + 1)
        #expect(store.workspaces.first?.id == item.id)
        #expect(item.name == "Fix the crash in tab restore")
        #expect(item.status == .working)
        #expect(store.newWorkspaceMacID == "mini")
        #expect(store.create().name == "New workspace")
    }

    @Test func openingClearsUnreadAndAnsweringAPromptChangesStatus() {
        let store = WorkspacesStore.sample()
        store.open("wg")
        #expect(store.workspace("wg")?.unreadCount == 0)
        store.resolvePrompt("wg", allow: true)
        #expect(store.workspace("wg")?.status == .working)
        #expect(store.othersNeedingYou(besides: "rel") == 1)
    }

    @Test func renameIgnoresBlankNames() {
        let store = WorkspacesStore.sample()
        store.rename("hq", to: "   ")
        #expect(store.workspace("hq")?.name == "hq")
        store.rename("hq", to: "Headquarters")
        #expect(store.workspace("hq")?.name == "Headquarters")
    }
}

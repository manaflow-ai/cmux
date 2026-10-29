import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Observation
import Testing

/// The real list tells its row feed what it shows (feature `sidebarRowsNearViewport`):
/// 400 laid-out rows under a 30-row clip at an unaligned offset arm only the rows on screen, a jump to a
/// far row draws its current content with no flush pending, and a filter reads every row current.
@MainActor @Suite(.serialized) struct SidebarListRowWatchTests {
    @Observable final class Title {
        var text: String
        init(_ text: String) { self.text = text }
    }

    final class Pending {
        var work: [@MainActor @Sendable () -> Void] = []
    }

    final class Harness {
        let ids: [WorkspaceID]
        let titles: [WorkspaceID: Title]
        let ledger: ObservationLedger
        let pending: Pending
        let feed: SidebarRowFeed
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var list: SidebarListView { sidebar.list }
        var clip: NSClipView { list.enclosingScrollView!.contentView }

        /// `count` loose rows; with `grouped`, the last `grouped` of them sit in one open group.
        init(rows count: Int, grouped: Int = 0) {
            _ = NSApplication.shared
            let ids = (0..<count).map { WorkspaceID("lw\($0)") }
            let titles = Dictionary(uniqueKeysWithValues: ids.map { ($0, Title($0.rawValue)) })
            let ledger = ObservationLedger(), pending = Pending()
            let feed = SidebarRowFeed(schedule: { pending.work.append($0) }, observations: ledger.owner("SidebarRows"))
            feed.beginPass(inputs: 0)
            let rows = ids.map { id in
                feed.row(id, machine: .local) { SidebarWorkspace(id: id, machineID: .local, title: titles[id]?.text ?? "") }
            }
            let loose = rows.count - grouped
            var nodes: [SidebarNode] = rows[..<loose].map { .workspace($0) }
            if grouped > 0 {
                nodes.append(.group(SidebarGroup(id: GroupID("lw-group"), name: "Group", color: .green, workspaces: Array(rows[loose...]))))
            }
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let model = SidebarModel(sections: feed.fill([SidebarSection(kind: .machine(machine), nodes: nodes)]), activeWorkspaceID: ids.first)
            // As the app's `SidebarRows.patch`: a patch the model cannot apply in place (a filter) rebuilds its rows.
            feed.onChange = { [weak model] changed in
                guard let model, !model.patchWorkspaces(changed) else { return }
                model.sections = SidebarSection.patching(changed, in: model.sections)
            }
            self.ids = ids
            self.titles = titles
            self.ledger = ledger
            self.pending = pending
            self.feed = feed
            self.model = model
            sidebar = SidebarView(model: model, design: DesignSettings())
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = sidebar
            window.orderFrontRegardless()
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            // A test window's occlusion is not what these tests check (a hidden list arms no row: SidebarRowFeedTests).
            sidebar.list.visibility.set(.visible)
        }

        var rowHeight: CGFloat { list.displayed.rows.first { if case .workspace = $0.key { true } else { false } }?.height ?? 0 }

        /// Makes the clip `rows` rows tall.
        func fitClip(rows: Int) {
            let height = sidebar.frame.height + CGFloat(rows) * rowHeight - clip.bounds.height
            window.setContentSize(NSSize(width: 260, height: height))
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: height)
            sidebar.layoutSubtreeIfNeeded()
        }

        func scroll(to y: CGFloat) {
            list.scrollClip(to: min(max(0, y), list.displayed.totalHeight - clip.bounds.height), animated: false)
        }

        /// The workspace rows the clip shows (a row that only touches an edge is out).
        var onScreen: Set<WorkspaceID> {
            let rect = clip.bounds
            return Set(list.displayed.rows.compactMap { row -> WorkspaceID? in
                guard case let .workspace(id) = row.key, row.y < rect.maxY, row.y + row.height > rect.minY else { return nil }
                return id
            })
        }

        /// Writes the store's title of `id`, as an OSC title or an agent does.
        func rename(_ id: WorkspaceID, _ text: String) {
            if let title = titles[id] { title.text = text }
        }

        func armed() throws -> Int { try #require(ledger.snapshot().first).armed }

        func row(_ index: Int) throws -> SidebarRow { try #require(list.displayed.row(for: .workspace(ids[index]))) }
    }

    init() { Motion.reduceMotionOverride = true }

    @Test func fourHundredRowsUnderAThirtyRowClipArmAtMostSixty() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(rows: 400)
        defer { h.window.close() }
        h.fitClip(rows: 30)
        h.sidebar.rowFeed = h.feed
        try h.scroll(to: h.row(150).y + h.rowHeight / 2)

        let shown = h.onScreen
        #expect((29...31).contains(shown.count), "the clip shows about 30 rows: \(shown.count)")
        #expect(try h.armed() <= 60)
        #expect(try h.armed() == shown.count, "only the rows on screen are armed")

        h.list.visibility.set(.occluded) // the window is covered or miniaturized
        #expect(try h.armed() == 0)
        h.list.visibility.set(.visible)
        #expect(try h.armed() == shown.count)
    }

    @Test func fourHundredRowsInOneOpenGroupScrolledToTheTopArmAtMostSixty() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(rows: 400, grouped: 400)
        defer { h.window.close() }
        h.fitClip(rows: 30)
        h.sidebar.rowFeed = h.feed
        h.scroll(to: 0)
        #expect(h.list.displayed.row(for: .group(GroupID("lw-group"))).map { $0.y < h.clip.bounds.maxY } == true,
                "the group's header is on screen")
        #expect(try h.armed() <= 60)
        #expect(try h.armed() == h.onScreen.count, "the header rolls its members up without arming them")
    }

    @Test func aGroupHeaderOffScreenArmsNoneOfItsMembers() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(rows: 400, grouped: 200)
        defer { h.window.close() }
        h.fitClip(rows: 30)
        h.sidebar.rowFeed = h.feed
        #expect(try h.armed() == h.onScreen.count, "the group's header is far below: its members keep a sentinel")
    }

    @Test func aJumpToAFarRowDrawsItsCurrentContentAtOnce() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(rows: 400)
        defer { h.window.close() }
        h.fitClip(rows: 30)
        h.sidebar.rowFeed = h.feed
        let far = h.ids[300]
        h.rename(far, "renamed off screen")
        #expect(h.list.workspaces[far]?.title == far.rawValue, "off screen: not mapped")

        try h.scroll(to: h.row(290).y)
        #expect(h.onScreen.contains(far))
        #expect(h.list.workspaces[far]?.title == "renamed off screen", "patched in the scroll's own turn")
        #expect(h.pending.work.isEmpty, "no flush is needed to draw it")
    }

    @Test func aFilterReadsEveryRowCurrent() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(rows: 400)
        defer { h.window.close() }
        h.fitClip(rows: 30)
        h.sidebar.rowFeed = h.feed
        let far = h.ids[300]
        h.rename(far, "zebra")

        h.model.filterText = "zebra"
        h.sidebar.renderNow() // the filter's layout: every row is read again, the stale one now
        h.sidebar.renderNow()
        #expect(h.model.filterMatches == [far], "the filter matches the store's title, not the old row")
        #expect(h.list.displayed.row(for: .workspace(far)) != nil)
        #expect(try h.armed() == 400, "while filtering every row stays armed")
    }
}

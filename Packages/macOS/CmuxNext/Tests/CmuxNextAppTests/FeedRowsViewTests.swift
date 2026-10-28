import AppKit
@testable import CmuxNextFeed
import Foundation
import Testing

/// The Feed list (panel and Inbox column) is one AppKit table over the feed model: its event rows
/// are AppKit cells that say what happened, who, where and when; one owner event redraws only the
/// row it changed; an event above the reader keeps the reader's row in place; a click selects
/// and reads the item.
@MainActor @Suite struct FeedRowsViewTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ index: Int, ago seconds: TimeInterval, dedupe: String? = nil) -> FeedItem {
        FeedItem(id: "fi_\(index)", title: "Finished: updated FeedModel.swift (\(index))",
                 body: "Ran `swift test --filter FeedModelTests`: 42 passed.\nMore detail.",
                 dedupeKey: dedupe, context: FeedContext(tab: "tab_\(index % 3)"),
                 poster: FeedPoster(kind: .agent, label: "Agent"), createdAt: now.addingTimeInterval(-seconds))
    }

    private func shown(count: Int, mode: FeedRowsView.Mode = .list, height: CGFloat = 600, resolves: Bool = true)
        -> (FeedRowsView, FeedModel, InMemoryFeedSource, NSWindow) {
        let items = (0..<count).map { item($0, ago: Double($0) * 60 + 30, dedupe: "d\($0)") }
        let source = InMemoryFeedSource(snapshot: FeedSnapshot(revision: 1, user: "usr_me", device: "Mac", items: items))
        let model = FeedModel(source: source, clock: { [now] in now })
        model.place = { item in
            resolves ? FeedPlace(agent: "Claude Code", workspace: "api-server", tab: "Fix login \(item.context.tab ?? "")") : nil
        }
        model.start()
        let view = FeedRowsView(model: model, mode: mode)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.table.layoutSubtreeIfNeeded()
        return (view, model, source, window)
    }

    /// Lets main-actor tasks run until `condition` holds (bounded).
    private func until(_ condition: () -> Bool) async {
        var tries = 0
        while !condition(), tries < 400 {
            tries += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func subviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(subviews(of:))
    }

    private func visibleCells(_ view: FeedRowsView) -> [String: FeedRowCell] {
        var cells: [String: FeedRowCell] = [:]
        view.table.enumerateAvailableRowViews { rowView, _ in
            if let cell = rowView.view(atColumn: 0) as? FeedRowCell, let id = cell.content?.id { cells[id] = cell }
        }
        return cells
    }

    @Test func eventRowsAreAppKitCells() {
        let (view, _, _, window) = shown(count: 40)
        defer { window.close() }
        let swiftUI = subviews(of: view).map { NSStringFromClass(type(of: $0)) }.filter { $0.contains("SwiftUI") }
        #expect(swiftUI.isEmpty, "SwiftUI views in the Feed list: \(swiftUI)")
        #expect(view.entries.count == 40)
        #expect(!visibleCells(view).isEmpty)
    }

    @Test func aRowSaysWhatWhoWhereAndWhen() throws {
        let (view, _, _, window) = shown(count: 3)
        defer { window.close() }
        let cell = try #require(visibleCells(view)["fi_1"])
        #expect(cell.headline.stringValue == "Finished: updated FeedModel.swift (1)")
        #expect(cell.detail.stringValue == "Ran swift test --filter FeedModelTests: 42 passed.")
        #expect(cell.meta.stringValue.contains("Claude Code"))
        #expect(cell.meta.stringValue.contains("api-server › Fix login tab_1"))
        #expect(cell.time.stringValue.contains("1"), "1m 30s ago reads as 1 minute: \(cell.time.stringValue)")
        let row = try #require(view.table.rowView(atRow: 1, makeIfNecessary: false))
        let label = row.accessibilityLabel() ?? ""
        for part in ["Claude Code", "api-server › Fix login tab_1", "Finished: updated FeedModel.swift (1)", "42 passed"] {
            #expect(label.contains(part), "\(part) missing from \(label)")
        }
    }

    @Test func oneOwnerEventRedrawsOnlyItsRow() async throws {
        let (view, _, source, window) = shown(count: 30)
        defer { window.close() }
        let before = visibleCells(view)
        let renders = view.renderCount
        // An agent repeats its notice: the owner coalesces it into fi_2 (count 2).
        source.post(item(99, ago: 0, dedupe: "d2"))
        await until { view.renderCount > renders }
        let index = try #require(view.entries.firstIndex { $0.id == "fi_2" })
        #expect(view.lastReloaded == IndexSet(integer: index), "reloaded \(Array(view.lastReloaded)), want only \(index)")
        let after = visibleCells(view)
        for (id, cell) in before where id != "fi_2" {
            #expect(after[id] === cell, "\(id) got a new cell")
        }
        #expect(after["fi_2"]?.meta.stringValue.contains("×2") == true)
    }

    /// A live event costs the rows it changed, not the list: at 1,500 items one coalesced notice
    /// builds one row value, also when no item's place resolves (another Mac's items).
    @Test(arguments: [true, false]) func oneEventBuildsOneRowValue(resolves: Bool) async throws {
        let (view, model, source, window) = shown(count: 1_500, resolves: resolves)
        defer { window.close() }
        let builds = view.contentBuilds
        #expect(builds == 1_500)
        let renders = view.renderCount
        source.post(item(99, ago: 0, dedupe: "d7"))
        await until { view.renderCount > renders }
        #expect(model.item("fi_7")?.count == 2)
        #expect(view.contentBuilds - builds == 1, "a render built \(view.contentBuilds - builds) row values")
    }

    @Test func aNewEventAboveKeepsTheReadersRow() async throws {
        let (view, _, source, window) = shown(count: 120, height: 400)
        defer { window.close() }
        let target = view.table.rect(ofRow: 60).minY
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
        let topRow = view.table.row(at: NSPoint(x: 1, y: view.scroll.contentView.bounds.minY + 1))
        let anchor = view.entries[topRow].id
        let renders = view.renderCount
        source.post(item(500, ago: 0))
        await until { view.renderCount > renders }
        #expect(view.entries.first?.id == "fi_500")
        let nowTop = view.table.row(at: NSPoint(x: 1, y: view.scroll.contentView.bounds.minY + 1))
        #expect(view.entries[nowTop].id == anchor, "the reader's row moved: \(view.entries[nowTop].id) is on top, not \(anchor)")
    }

    @Test func aClickSelectsAndReadsTheItem() async throws {
        let (view, model, _, window) = shown(count: 5)
        defer { window.close() }
        let entry = try #require(view.entries.first { $0.id == "fi_3" })
        view.clicked(entry, clickCount: 1)
        #expect(model.selection == "fi_3")
        await until { model.item("fi_3")?.isUnread == false }
        #expect(model.item("fi_3")?.isUnread == false)
        await until { visibleCells(view)["fi_3"]?.content?.isUnread == false }
        #expect(visibleCells(view)["fi_3"]?.content?.isUnread == false)
    }

    @Test func theInboxGroupsRowsUnderTitles() {
        let (view, _, _, window) = shown(count: 4, mode: .inbox)
        defer { window.close() }
        guard case .header = view.entries.first else {
            Issue.record("the Inbox list starts with a section title: \(view.entries.map(\.id))")
            return
        }
        #expect(view.entries.filter { if case .row = $0 { true } else { false } }.count == 4)
    }

    /// Rows say who and where even when the poster named nobody, and never print an opaque id.
    @Test func contentNamesThePosterOnlyWhenItSaysSomething() {
        let bridge = FeedItem(id: "fi_a", title: "Allow Bash?",
                              prompt: .approve(.init(action: .init(type: .command, summary: "Run", command: "rm -rf build\nnpm run build"))),
                              context: FeedContext(host: "inst_1", acpSession: "ses_9"),
                              poster: FeedPoster(kind: .agent, label: "Agent"), createdAt: now)
        var answered = bridge
        answered.state = .answered
        answered.answer = FeedAnswerRecord(value: .approve(.init(.allow)), by: "usr_me", device: "", at: now)
        #expect(FeedRowContent(item: answered, place: nil).status == "Answered", "no device: no dangling \"Answered on\"")
        let bare = FeedRowContent(item: bridge, place: nil)
        #expect(bare.who.isEmpty && bare.place.isEmpty, "\(bare.who) / \(bare.place)")
        #expect(bare.detail == "rm -rf build" && bare.detailIsCode)
        let named = FeedRowContent(item: bridge, place: FeedPlace(agent: "Claude", workspace: "cmux-next", tab: "Feed perf"))
        #expect(named.meta == "Claude · cmux-next › Feed perf")
        let hook = FeedItem(id: "fi_b", title: "Run make?", poster: FeedPoster(kind: .harness, label: "api-server", harness: "Claude Code"),
                            createdAt: now)
        #expect(FeedRowContent(item: hook, place: nil).meta == "Claude Code · api-server")
        let github = FeedItem(id: "fi_c", title: "GitHub", body: "manaflow-ai/cmux#26530",
                              poster: FeedPoster(kind: .integration, label: "GitHub"), createdAt: now)
        let row = FeedRowContent(item: github, place: nil)
        #expect(row.headline == "manaflow-ai/cmux#26530" && row.detail.isEmpty)
    }
}

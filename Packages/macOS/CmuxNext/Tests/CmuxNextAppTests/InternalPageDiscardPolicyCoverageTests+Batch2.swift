import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
import CmuxNextBookmarks
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHibernation
import CmuxNextHistory
@testable import CmuxNextTasks
import CmuxNextWakeupsTestSupport
import Foundation
import SwiftUI
import Testing

/// Page policies batch 2: history, bookmarks, passwords, stashed, tasks and
/// workspace todo each declare when their hidden tab's view may go and what comes back. Passwords
/// goes one minute after it hides and keeps no view state and no picture; an edit in progress
/// (a todo item, a bookmark sheet) keeps the view; the rest come back as they were.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct InternalPageDiscardPolicyCoverageTestsBatch2 {
    @Test func eachPageOfTheBatchHasItsPolicy() {
        let services = Self.services()
        let providers: [any InternalPageProvider] = [
            HistoryTopPage(services: services), BookmarksTopPage(services: services),
            PasswordsPageService(services: services, store: SamplePasswordStore()), StashTopPage(services: services),
            services.tasks, services.workspaceTodo,
        ]
        let expected: [InternalPageID: ContentDiscardPolicy] = [
            .history: .standard, .bookmarks: .standard, .passwords: .afterHidden(.seconds(60)),
            .stashed: .standard, .tasks: .standard, .workspaceTodo: .standard,
        ]
        #expect(Set(providers.map { $0.page }) == Set(expected.keys))
        for provider in providers {
            #expect(provider.discardPolicy(for: "any") == expected[provider.page], "\(provider.page.rawValue)")
            #expect(provider.keepsDiscardPicture(for: "any") == (provider.page != .passwords), "\(provider.page.rawValue) picture")
        }
    }

    @Test func passwordsGoesOneMinuteAfterItHidesAndKeepsNoViewStateOrPicture() async throws {
        let services = Self.services()
        let passwords = PasswordsPageService(services: services, store: SamplePasswordStore())
        let rig = Rig(services, passwords)
        _ = try #require(rig.pages.view(for: rig.key))
        rig.show()
        rig.hide()
        #expect(rig.discards.nextCheck == 60, "a hidden Passwords page waits its one minute")
        // A picture of the listing from before (a cover, a preview) must not outlive the page.
        rig.cache.internalPagePictures.insert(PurgeablePicture(resident: try #require(Self.picture())), for: rig.key)

        rig.advance(59)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) != nil, "gone before its minute")

        rig.advance(2)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) == nil, "a hidden Passwords page outlived its minute")
        #expect(rig.cache.phase(of: rig.key) == .hibernated)
        #expect(rig.pages.discardRecords.discarded[rig.key]?.state == ContentViewState(), "a secrets page keeps no search, row or scroll")
        #expect(rig.cache.internalPagePictures.image(for: rig.key) == nil, "the listing stays as a picture")
    }

    @Test func todoKeepsItsViewWhileAnItemIsEditedAndItsDraftAfter() async throws {
        let services = Self.services()
        let rig = Rig(services, services.workspaceTodo)
        _ = try #require(rig.pages.view(for: rig.key))
        let model = try #require(services.workspaceTodo.models[rig.key])
        model.draft = "call the bank"
        model.editing = "item-1"
        #expect(services.workspaceTodo.keepReasons(for: rig.key) == [.unsavedEdits])
        rig.show()
        rig.hide()
        await rig.discardDue()
        #expect(rig.pages.existingView(rig.key) != nil, "a todo page lost an item's edit")
        #expect(rig.discards.exemptions[rig.key] == .unsavedEdits)

        model.editing = nil
        #expect(services.workspaceTodo.keepReasons(for: rig.key).isEmpty)
        await rig.discardDue()
        #expect(rig.pages.existingView(rig.key) == nil)

        _ = try #require(rig.pages.view(for: rig.key))
        #expect(services.workspaceTodo.models[rig.key] === model, "the rebuilt view shows the same checklist model")
        #expect(model.draft == "call the bank", "the unsent draft is lost")
    }

    /// The New Task title is the shared model's, so the view goes and the title comes back.
    @Test func tasksLetsItsViewGoAndKeepsATypedTitle() async throws {
        let services = Self.services()
        let rig = Rig(services, services.tasks)
        _ = try #require(rig.pages.view(for: rig.key))
        let model = try #require(services.tasks.model)
        model.newTaskDraft = "Write the release notes"
        #expect(services.tasks.keepReasons(for: rig.key).isEmpty, "the title is in the model: nothing pins the view")
        rig.show()
        rig.hide()
        await rig.discardDue()
        #expect(rig.pages.existingView(rig.key) == nil)

        _ = try #require(rig.pages.view(for: rig.key))
        #expect(services.tasks.model === model)
        #expect(model.newTaskDraft == "Write the release notes", "the typed title is lost")
    }

    /// The real New Task field shows the model's draft and writes what is typed back to it.
    @Test func theNewTaskFieldIsTheModelsDraft() throws {
        let model = TasksModel(source: MockTasksSource())
        model.newTaskDraft = "Write the release notes"
        model.focusNewTask()
        let (window, root) = Self.host(NewTaskField(model: model))
        defer { window.contentView = nil; window.close() }
        let field = try #require(HomeSheetThemeTests.editableFields(in: root).first)
        #expect(field.stringValue == "Write the release notes", "a field made again shows the draft")

        Self.settle(root) { field.currentEditor() != nil }
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Buy milk", replacementRange: editor.selectedRange())
        Self.settle(root) { model.newTaskDraft == "Buy milk" }
        #expect(model.newTaskDraft == "Buy milk", "typing goes to the model: \(model.newTaskDraft)")

        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        Self.settle(root) { model.newTaskDraft.isEmpty }
        #expect(model.newTaskDraft.isEmpty, "Escape clears the draft")
    }

    @Test func bookmarksKeepsItsViewWhileTheEditorIsOpen() async throws {
        let services = Self.services()
        let bookmarks = BookmarksTopPage(services: services)
        let rig = Rig(services, bookmarks)
        _ = try #require(rig.pages.view(for: rig.key))
        let model = try #require(bookmarks.pages[rig.key]?.model)
        #expect(bookmarks.keepReasons(for: rig.key).isEmpty)
        model.startAddBookmark()
        #expect(bookmarks.keepReasons(for: rig.key) == [.unsavedEdits])
        rig.show()
        rig.hide()
        await rig.discardDue()
        #expect(rig.pages.existingView(rig.key) != nil, "a bookmarks page lost its open editor")
        #expect(rig.discards.exemptions[rig.key] == .unsavedEdits)

        model.editor = nil
        await rig.discardDue()
        #expect(rig.pages.existingView(rig.key) == nil)
    }

    @Test func bookmarksGetsItsFolderSearchSelectionAndScrollBack() async throws {
        let services = Self.services()
        services.bookmarks.trees["default"] = try Self.bookmarkTree()
        let bookmarks = BookmarksTopPage(services: services)
        let rig = Rig(services, bookmarks)
        let window = Self.window()
        defer { window.contentView = nil; window.close() }

        let view = try #require(rig.pages.view(for: rig.key))
        let first = try #require(bookmarks.pages[rig.key])
        #expect(first.model.folder != "bm_work", "the page opens on the bar")
        first.model.folder = "bm_work"
        first.model.query = "site"
        first.model.selection = ["bm_3", "gone-bookmark"]
        window.contentView = view
        let saved = try Self.scrollList(in: view, to: 300)
        window.contentView = nil
        rig.show()
        rig.hide()
        await rig.discardDue()
        #expect(rig.pages.existingView(rig.key) == nil)
        #expect(bookmarks.pages[rig.key] == nil, "the discarded page is still kept")

        let rebuilt = try #require(rig.pages.view(for: rig.key))
        window.contentView = rebuilt
        rebuilt.layoutSubtreeIfNeeded()
        await rebuilt.restoring?.value
        let second = try #require(bookmarks.pages[rig.key])
        #expect(second !== first)
        #expect(second.model.folder == "bm_work")
        #expect(second.model.query == "site")
        #expect(second.model.selection == ["bm_3"], "a selected bookmark missing from the tree came back")
        let scroll = try #require(rebuilt.content.listScrollView)
        #expect(abs(scroll.documentVisibleRect.origin.y - saved) < 1, "scroll \(scroll.documentVisibleRect.origin.y), saved \(saved)")
    }

    /// The restore's search and filter make one reload; the selection goes back with its rows.
    @Test func historyRestoresItsQueryWithOneReloadAndItsSelectionWithTheRows() async {
        let source = HistorySource(entries: Self.historyEntries())
        let model = HistoryPageModel(source: source)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            model.restore(text: "swift", filter: .pages, selection: "page:default:2") { done.resume() }
            #expect(model.selection == nil, "the selection goes back before its rows")
        }
        #expect(source.queries.map(\.text) == ["swift"], "the restore reloaded \(source.queries.count) times")
        #expect(source.queries.first?.kinds == [.page])
        #expect(model.selection == "page:default:2")
    }

    /// The native History page puts its scroll back once the reload's rows are in, not before (an
    /// empty list clamps it to the top).
    @Test func historyScrollsBackAfterTheRestoredRowsLoad() throws {
        let services = Self.services()
        let history = HistoryTopPage(services: services)
        let key = LocalPageTab.makeKey(.history)
        _ = history.makeView(for: key, in: nil)
        defer { history.tabClosed(key) }
        let model = try #require(history.pages[key]?.model)
        let rows = TableRows()
        let content = Self.scrollingList(rows)
        let state = ContentViewState(scroll: CGPoint(x: 0, y: 500), search: "swift", selection: "page:default:2",
                                     values: [HistoryTopPage.filterValue: HistoryPageModel.Filter.pages.rawValue])
        history.restoreViewState(state, for: key, content: content)
        #expect(model.text == "swift")
        #expect(model.filter == .pages)
        #expect(content.documentVisibleRect.origin.y == 0, "scrolled before the rows are in")

        model.apply(Self.historyEntries())
        #expect(model.selection == "page:default:2")
        #expect(content.documentVisibleRect.origin.y == 500)
    }

    @Test func historyGetsItsSearchFilterAndSelectionBackAfterADiscard() async throws {
        let services = Self.services()
        let source = HistorySource(entries: Self.historyEntries())
        let history = HistoryTopPage(services: services)
        let rig = Rig(services, history)
        _ = try #require(rig.pages.view(for: rig.key))
        let first = try #require(history.pages[rig.key])
        first.model.source = source
        first.model.filter = .pages
        first.model.text = "swift"
        first.model.apply(Self.historyEntries())
        first.model.selection = "page:default:2"
        rig.show()
        rig.hide()
        await rig.discardDue()
        #expect(rig.pages.existingView(rig.key) == nil)
        #expect(history.pages[rig.key] == nil, "the discarded page is still kept")

        let rebuilt = try #require(rig.pages.view(for: rig.key))
        let second = try #require(history.pages[rig.key])
        second.model.source = source
        rebuilt.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        rebuilt.layoutSubtreeIfNeeded()
        await rebuilt.restoring?.value
        #expect(second !== first)
        #expect(second.model.text == "swift")
        #expect(second.model.filter == .pages)
        second.model.apply(Self.historyEntries())
        #expect(second.model.selection == "page:default:2")
    }

    // MARK: Rig

    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    /// A page tab on the discard framework, as `AppMemoryConsumers` wires it with the feature on.
    @MainActor final class Rig {
        let services: AppServices
        let clock = ManualClock()
        let discards: ContentDiscardScheduler
        let pane = Pane()
        let key: String
        var cache: TabContentCache { services.cache }
        var pages: InternalPageTabStore { services.pages }

        init(_ services: AppServices, _ provider: any InternalPageProvider) {
            self.services = services
            discards = ContentDiscardScheduler(kind: .internalPage, clock: clock)
            services.pages.register(provider)
            // What AppMemoryConsumers does with `memoryDiscardInternalPages` on.
            services.pages.enableDiscards(discards, on: services.cache)
            key = services.pages.open(provider.page, in: "pane-batch2-test", of: DaemonStore())
        }

        func show() { cache.present(key, by: pane, presence: .visible) }
        func hide() { cache.withdraw(key, by: pane) }
        func advance(_ seconds: Int64) { clock.advance(by: .seconds(seconds)) }

        /// Ten minutes and one second later: a standard policy is due.
        func discardDue() async {
            advance(601)
            discards.replan()
            await discards.settled()
        }
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }

    @MainActor final class HistorySource: HistoryPageSource {
        let rows: [HistoryEntry]
        private(set) var queries: [HistoryQuery] = []

        init(entries: [HistoryEntry]) { rows = entries }

        func entries(_ query: HistoryQuery) async -> [HistoryEntry] {
            queries.append(query)
            return rows
        }

        func open(_ entry: HistoryEntry, newTab: Bool) {}
        func remove(_ entry: HistoryEntry) {}
        func removeSite(of entry: HistoryEntry) {}
        func clear(range: HistoryRange) {}
        func copy(_ text: String) {}
        func cookieBackups() async -> [HistoryCookieBackup] { [] }
        func deleteCookieBackups(_ ids: [String]) async {}
    }

    @MainActor final class TableRows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 100 }
    }

    static func historyEntries() -> [HistoryEntry] {
        (0..<4).map {
            HistoryEntry(id: "page:default:\($0)", kind: .page, time: Date(timeIntervalSince1970: 1_800_000_000 - Double($0) * 60),
                         title: "Swift \($0)", payload: .page(url: "https://swift.org/\($0)", profile: "default"))
        }
    }

    /// A bar with folder "Work" (`bm_work`) holding sixty bookmarks `bm_0`…`bm_59` titled "Site N".
    static func bookmarkTree() throws -> BookmarkTree {
        var tree = BookmarkTree()
        try tree.apply(.create(.folder("Work", in: BookmarkRoot.bar.rawValue, id: "bm_work"), index: nil))
        for index in 0..<60 {
            let url = try #require(URL(string: "https://example.com/\(index)"))
            try tree.apply(.create(.bookmark("Site \(index)", url: url, in: "bm_work", id: "bm_\(index)"), index: nil))
        }
        return tree
    }

    /// A list scroll view (a table, as a SwiftUI `List` is) a hundred rows tall.
    static func scrollingList(_ rows: TableRows) -> NSScrollView {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        table.rowHeight = 20
        table.dataSource = rows
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.documentView = table
        table.reloadData()
        return scroll
    }

    /// Lays out `view`'s list in its window and scrolls it to `y`; the position it took.
    static func scrollList(in view: InternalPageView, to y: CGFloat) throws -> CGFloat {
        view.layoutSubtreeIfNeeded()
        let scroll = try #require(view.content.listScrollView, "the bookmarks list has no table scroll view")
        settle(view) { (scroll.documentView?.frame.height ?? 0) > scroll.contentSize.height + y }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        let origin = scroll.documentVisibleRect.origin.y
        #expect(origin > 0, "the list did not scroll")
        return origin
    }

    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    static func host(_ view: some View) -> (NSWindow, NSView) {
        let window = Self.window()
        let hosting = NSHostingView(rootView: view.frame(width: 520, height: 80))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    /// Runs the main run loop in short turns until `condition` holds, two seconds at most.
    static func settle(_ root: NSView, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            root.layoutSubtreeIfNeeded()
        }
    }

    static func picture() -> CGImage? {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context?.makeImage()
    }
}

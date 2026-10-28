import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextPages
import CmuxNextResources
@testable import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import SwiftUI
import Testing

/// Page policies, batch 1 (`memoryDiscardInternalPages`, p07-memory-024): Settings, Debug Settings,
/// Keyboard Shortcuts, the changelog (What's New), Stats and the Task Manager each declare when a
/// hidden tab's view may go, what keeps it, and what the view built again shows. Every test calls
/// the provider methods the tab store calls (InternalPageTabStore+Show).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct InternalPageDiscardPolicyCoverageTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Each page of the batch, the source that declares its policy, and the declaration there: a
    /// provider's own `discardPolicy(for:)`, a `WebPageTab`'s `discardPolicy:` argument, or the
    /// `// discard: default <why>` marker (p07-memory-029).
    static let batchOne: [(page: InternalPageID, source: String, declaration: String)] = [
        (.settings, "Sources/CmuxNextApp/Settings/SettingsWindowService.swift", "func discardPolicy(for key: String)"),
        (.debugSettings, "Sources/CmuxNextApp/Settings/DebugSettingsService.swift", "func discardPolicy(for key: String)"),
        (.keybindings, "Sources/CmuxNextApp/Focus/Keybindings/KeybindingsPage.swift", "func discardPolicy(for key: String)"),
        (.changelog, "Sources/CmuxNextApp/Pages/ChangelogPageTab.swift", "func discardPolicy(for key: String)"),
        (.stats, "Sources/CmuxNextApp/Pages/StatsPage.swift", "discardPolicy: ."),
        (.taskManager, "Sources/CmuxNextApp/TaskManager/TaskManagerPageService.swift", "func discardPolicy(for key: String)"),
    ]

    static func services() -> AppServices {
        let services = TaskManagerActionTests.services()
        ChangelogPageTab.register(services)
        return services
    }

    /// Services with a settings owner over an empty cmux.json, as the app has once it loads.
    static func servicesWithSettings() async throws -> AppServices {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-page-discard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = Self.services()
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        return services
    }

    /// Calls page op `op` on `page` as the page's script does (one `call` envelope to its router).
    static func call(_ page: PageWebView, _ op: String, _ params: JSONValue = .object([:])) async -> JSONValue {
        await page.router.handle(["t": "call", "id": 1, "op": .string(op), "params": params])
    }

    // MARK: Every page of the batch declares its policy

    @Test func everyPageOfTheBatchDeclaresItsPolicy() throws {
        let services = Self.services()
        for entry in Self.batchOne {
            #expect(services.pages.provider(entry.page) != nil, "\(entry.page.rawValue) registers at launch")
            let source = try String(contentsOf: Self.packageRoot.appending(path: entry.source), encoding: .utf8)
            #expect(source.contains(entry.declaration) || source.contains("// discard: default "),
                    "\(entry.page.rawValue) chose its policy in \(entry.source)")
        }
    }

    @Test func theTaskManagerGoesAMinuteAfterItHidesAndTheOthersAfterTen() throws {
        let services = Self.services()
        for entry in Self.batchOne {
            let provider = try #require(services.pages.provider(entry.page))
            let expected: ContentDiscardPolicy = entry.page == .taskManager ? .afterHidden(.seconds(60)) : .standard
            #expect(provider.discardPolicy(for: "tab") == expected, "\(entry.page.rawValue)")
        }
    }

    // MARK: Settings

    @Test func settingsKeepsItsPageWhileAPreviewRuns() async throws {
        let services = try await Self.servicesWithSettings()
        let settings = try #require(services.settings)
        let key = LocalPageTab.makeKey(.settings)
        _ = services.settingsWindow.makeView(for: key, in: nil)
        #expect(services.settingsWindow.keepReasons(for: key).isEmpty)
        let opacity = try #require(SettingsSchema.descriptor(for: CmuxConfigFile.keyPath(from: "appearance.backgroundOpacity")))
        #expect(settings.preview(opacity, .number(0.5)))
        #expect(services.settingsWindow.keepReasons(for: key) == [.unsavedEdits], "a value shown and not written")
        settings.endPreview()
        #expect(services.settingsWindow.keepReasons(for: key).isEmpty)
        services.settingsWindow.tabClosed(key)
    }

    @Test func settingsKeepsAPageWhoseFormHoldsUnsavedValues() async throws {
        let services = try await Self.servicesWithSettings()
        let key = LocalPageTab.makeKey(.settings), other = LocalPageTab.makeKey(.settings)
        let page = try #require(services.settingsWindow.makeView(for: key, in: nil) as? PageWebView)
        // Shown in a tab, so the second tab gets a page of its own (a second window's).
        let pane = NSView()
        pane.addSubview(page)
        let otherPage = try #require(services.settingsWindow.makeView(for: other, in: nil) as? PageWebView)
        #expect(page !== otherPage)
        let reply = await Self.call(page, "cmux.settings.editing", ["form": "relay:new", "editing": true])
        #expect(reply["t"]?.stringValue == "ok")
        #expect(services.settingsWindow.keepReasons(for: key) == [.unsavedEdits], "a relay form with typed values")
        #expect(services.settingsWindow.keepReasons(for: other).isEmpty, "only the page with the form is kept")
        _ = await Self.call(page, "cmux.settings.editing", ["form": "relay:new", "editing": false])
        #expect(services.settingsWindow.keepReasons(for: key).isEmpty)
        let refused = await Self.call(page, "cmux.settings.editing", ["form": "density"])
        #expect(refused["t"]?.stringValue == "err", "editing is required")
        withExtendedLifetime(pane) {}
        services.settingsWindow.tabClosed(key)
        services.settingsWindow.tabClosed(other)
    }

    @Test func aDiscardedSettingsPageIsNotKeptAndItsNextPageOpensWhereItWas() async throws {
        let services = try await Self.servicesWithSettings()
        let window = services.settingsWindow
        let key = LocalPageTab.makeKey(.settings)
        let first = try #require(window.makeView(for: key, in: nil) as? PageWebView)
        first.open(route: "#/settings/appearance")
        let state = await window.saveViewState(for: key, content: first)
        #expect(state.values[PageWebView.discardRouteKey] == "#/settings/appearance")
        window.viewDiscarded(key)
        let rebuilt = try #require(window.makeView(for: key, in: nil) as? PageWebView)
        #expect(rebuilt !== first, "the discarded page is not the kept page any more")
        await window.restoreViewState(state, for: key, content: rebuilt)
        #expect(rebuilt.route == "#/settings/appearance")
        window.tabClosed(key)
    }

    // MARK: Keyboard Shortcuts

    @Test func keyboardShortcutsKeepsItsPageWhileItRecords() async throws {
        let services = Self.services()
        let service = try #require(services.pages.provider(.keybindings) as? KeybindingsPageService)
        let key = LocalPageTab.makeKey(.keybindings)
        let page = try #require(service.makeView(for: key, in: nil) as? PageWebView)
        #expect(service.keepReasons(for: key).isEmpty)
        _ = await Self.call(page, "cmux.keybindings.record.start")
        #expect(service.keepReasons(for: key) == [.unsavedEdits], "a page taking the next key presses keeps its view")
        _ = await Self.call(page, "cmux.keybindings.record.stop")
        #expect(service.keepReasons(for: key).isEmpty)
        service.tabClosed(key)
    }

    @Test func aDiscardedKeyboardShortcutsTabMakesANewPageOnItsPlace() async throws {
        let services = Self.services()
        let service = try #require(services.pages.provider(.keybindings) as? KeybindingsPageService)
        let key = LocalPageTab.makeKey(.keybindings)
        let first = try #require(service.makeView(for: key, in: nil) as? PageWebView)
        first.open(route: "#/conflicts")
        _ = await Self.call(first, "cmux.keybindings.record.start")
        let state = await service.saveViewState(for: key, content: first)
        service.viewDiscarded(key)
        #expect(service.keepReasons(for: key).isEmpty, "the discarded page's recorder is no tab's")
        let rebuilt = try #require(service.makeView(for: key, in: nil) as? PageWebView)
        #expect(rebuilt !== first)
        await service.restoreViewState(state, for: key, content: rebuilt)
        #expect(rebuilt.route == "#/conflicts")
        service.tabClosed(key)
    }

    // MARK: The changelog (What's New)

    @Test func aDiscardedChangelogOpensWhereItWasUnlessAShowAskedForASpan() async throws {
        let services = Self.services()
        let provider = ChangelogPageTab.register(services)
        let key = LocalPageTab.makeKey(.changelog)
        let first = try #require(provider.makeView(for: key, in: nil) as? PageWebView)
        first.open(route: "#/?to=1.2.3")
        let state = await provider.saveViewState(for: key, content: first)
        provider.viewDiscarded(key)
        let rebuilt = try #require(provider.makeView(for: key, in: nil) as? PageWebView)
        #expect(rebuilt !== first)
        await provider.restoreViewState(state, for: key, content: rebuilt)
        #expect(rebuilt.route == "#/?to=1.2.3")

        // A page a show opened on a span stays on it.
        let asked = try #require(PageFactory(services: services).changelogPage(route: "#/?to=2.0.0"))
        await provider.restoreViewState(state, for: key, content: asked)
        #expect(asked.route == "#/?to=2.0.0")
        services.webUI.close(asked)
        provider.tabClosed(key)
    }

    // MARK: Task Manager

    @Test func eachTaskManagerTabSortsItsOwnTable() throws {
        let services = Self.services()
        let service = services.taskManager
        let one = LocalPageTab.makeKey(.taskManager), two = LocalPageTab.makeKey(.taskManager)
        _ = service.makeView(for: one, in: nil)
        _ = service.makeView(for: two, in: nil)
        let first = try #require(service.tables[one]), second = try #require(service.tables[two])
        first.sortOrder = TaskManagerSort.order("-memory")
        #expect(second.sort.isEmpty, "a sort in one window's table leaves the other's")
        service.tabClosed(one)
        service.tabClosed(two)
        #expect(service.tables.isEmpty)
    }

    @Test func aDiscardedTaskManagerStopsSamplingAndItsNextViewSortsAndScrollsAsBefore() async throws {
        let services = Self.services()
        let service = services.taskManager
        let key = LocalPageTab.makeKey(.taskManager)
        let content = service.makeView(for: key, in: nil)
        #expect(service.model?.isRunning == true)
        let table = try #require(service.tables[key])
        table.sortOrder = TaskManagerSort.order("-memory,process")
        var state = await service.saveViewState(for: key, content: content)
        #expect(state.values["sort"] == "-memory,process")
        service.viewDiscarded(key)
        #expect(service.model == nil, "the last view went: no sampling")
        #expect(service.tables[key] === table, "the tab keeps its table while it is open")

        table.sortOrder = []
        state.values["topRow"] = "local:4242"
        let rebuilt = service.makeView(for: key, in: nil)
        #expect(service.model?.isRunning == true)
        await service.restoreViewState(state, for: key, content: rebuilt)
        #expect(table.sort == "-memory,process")
        #expect(table.scrollTarget == ProcessKey(pid: 4242))
        service.tabClosed(key)
        #expect(service.model == nil)
    }

    @Test func theTaskManagerSortReadsBackAsItWasWritten() {
        let order = TaskManagerSort.order("-memory,process")
        #expect(order.compactMap(TaskManagerSort.init) == [TaskManagerSort(column: .memory, ascending: false),
                                                           TaskManagerSort(column: .process, ascending: true)])
        #expect(TaskManagerSort.text(order) == "-memory,process")
        #expect(TaskManagerSort.order("-nope,cpu").compactMap(TaskManagerSort.init) == [TaskManagerSort(column: .cpu, ascending: true)])
    }

    /// A table of `count` rows of 20 points in a 200-point scroll view, scrolled down by `offset`,
    /// in a container; the data source is returned too (a table holds its data source weakly).
    static func scrolledTable(count: Int, offset: CGFloat) -> (container: NSView, rows: Rows) {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        table.rowHeight = 20
        table.intercellSpacing = .zero
        table.headerView = nil
        let rows = Rows(count: count)
        table.dataSource = rows
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.documentView = table
        table.frame = NSRect(x: 0, y: 0, width: 300, height: CGFloat(count) * 20)
        table.reloadData()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        let container = NSView(frame: scroll.frame)
        container.addSubview(scroll)
        return (container, rows)
    }

    final class Rows: NSObject, NSTableViewDataSource {
        let count: Int
        init(count: Int) { self.count = count }
        func numberOfRows(in tableView: NSTableView) -> Int { count }
    }

    @Test func theTaskManagerSavesTheRowAtTheTopOfItsTable() {
        let rows = (0..<50).map { index in
            TaskManagerRow(id: ProcessKey(pid: Int32(1000 + index)), kind: .app, task: "t", name: "p", cpu: nil, memoryBytes: 0)
        }
        let scrolled = Self.scrolledTable(count: rows.count, offset: 400)
        #expect(TaskManagerPageService.topRow(in: scrolled.container, rows: rows) == ProcessKey(pid: 1020), "400 points down: row 20")
        let top = Self.scrolledTable(count: rows.count, offset: 0)
        #expect(TaskManagerPageService.topRow(in: top.container, rows: rows) == ProcessKey(pid: 1000))
        #expect(TaskManagerPageService.topRow(in: NSView(), rows: rows) == nil, "no table")
        withExtendedLifetime((scrolled.rows, top.rows)) {}
    }

    @Test func aRebuiltTaskManagerTableScrollsItsSavedRowToTheTop() async throws {
        let processes = (0..<60).map { ProcessKey(pid: Int32(2000 + $0)) }
        let tabs = processes.map { TabResourceSources(tabID: "tab_\($0.pid)", title: "t\($0.pid)", kind: .terminal, processes: [$0]) }
        let samples = Dictionary(uniqueKeysWithValues: processes.map { ($0, TaskManagerMemorySavedTests.sample($0, memory: 1 << 20)) })
        let source = TaskManagerMemorySavedTests.Source([TaskManagerSampleSet(resources: ResourceSampleSet(tabs: tabs, shared: [], samples: samples))])
        let model = TaskManagerModel(source: source, deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())),
                                     kill: { _ in })
        let table = TaskManagerTableState(scrollTarget: ProcessKey(pid: 2040))
        let host = NSHostingView(rootView: TaskManagerView(model: model, table: table))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        await model.refresh()
        let rows = table.rows(of: model.snapshot)
        #expect(rows.contains { $0.id == ProcessKey(pid: 2040) }, "a sample lists the saved row")
        for _ in 0..<150 where TaskManagerPageService.topRow(in: host, rows: rows) != ProcessKey(pid: 2040) {
            try? await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        #expect(table.scrollTarget == nil, "the table scrolled")
        #expect(TaskManagerPageService.topRow(in: host, rows: rows) == ProcessKey(pid: 2040))
    }
}

import AppKit
import CmuxNextActions
@testable import CmuxNextApp
#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
#else
import CmuxNextCompat
#endif
import CmuxNextCompatAppKit
import CmuxNextFiles
import CmuxNextFilesUI
import CmuxNextPages
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
import UniformTypeIdentifiers

/// Open With from kept answers (plans/cmux-next/chrome-parity/p02-threads.md, task 056): the apps that open a type
/// are asked of Launch Services on the system lane and kept per type (``WorkspaceQueries``), so the file explorer's
/// and the shared file menu's Open With submenus fill in the turn they open, with no Launch Services call and no
/// blocking seam on the main thread. The rows on screen warm their types' lists before a right-click.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct OpenWithCacheTests {
    static let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    static let xcode = URL(fileURLWithPath: "/Applications/Xcode.app")

    static func queries(_ system: OpenWithWorkspace) -> WorkspaceQueries {
        WorkspaceQueries(work: BackgroundWork(label: "test.open-with"), mainWork: .still(), system: system)
    }

    static func apps(_ system: OpenWithWorkspace) -> WorkspaceFileApps {
        WorkspaceFileApps(queries: queries(system))
    }

    /// Runs main run loop passes until `done` or 5 s.
    static func spin(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    /// The submenu's titles, a separator as "-".
    static func titles(_ menu: NSMenu?) -> [String] {
        (menu?.items ?? []).map { $0.isSeparatorItem ? "-" : $0.title }
    }

    @Test func theFirstListIsAskedOnTheSystemLaneNeverOnMain() async {
        let system = OpenWithWorkspace(apps: [Self.textEdit, Self.xcode], defaultApp: Self.textEdit)
        let apps = Self.apps(system)
        #expect(apps.keptOpenWithList(forFileNamed: "notes.txt", isDirectory: false) == nil)
        let list = await apps.openWithList(forFileNamed: "notes.txt", isDirectory: false)
        #expect(list.apps.map(\.name) == ["TextEdit", "Xcode"])
        #expect(list.apps.first?.isDefault == true)
        #expect(system.mainAsks.withLock { $0 } == 0, "Launch Services was asked on the main thread")
        #expect(apps.keptOpenWithList(forFileNamed: "readme.txt", isDirectory: false) == list, "one list per type, not per file")
    }

    @Test func theExplorersOpenWithFillsFromTheKeptListInItsFirstTurn() async throws {
        let system = OpenWithWorkspace(apps: [Self.textEdit, Self.xcode], defaultApp: Self.textEdit)
        let queries = Self.queries(system)
        let apps = WorkspaceFileApps(queries: queries)
        _ = await apps.openWithList(forFileNamed: "notes.txt", isDirectory: false)
        let menu = FileExplorerOpenWithMenu(registry: ActionRegistry.standard(), mainWork: MainWorkScheduler(budget: MainFrameBudget()), appIcon: { app, item in apps.showIcon(of: app, in: item) })
        let row = FileExplorerRow(url: URL(fileURLWithPath: "/tmp/readme.txt"), name: "readme.txt", depth: 0, isFolder: false, isExpanded: false)
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let item = BlockingViolationTable.$scoped.withValue(table) { menu.item(for: row, apps: apps) }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty, "the menu blocked the main thread")
        #else
        let item = menu.item(for: row, apps: apps)
        #endif
        #expect(Self.titles(item.submenu) == [FileExplorerStrings.defaultApp("TextEdit"), "-", "Xcode", "-", FileExplorerStrings.openWithOther])
        // The rows' icons come from the system lane (warmed with the list), then stay kept.
        let icon = WorkspaceQuery<NSImage>.fileIcon(atPath: Self.textEdit.path, side: 16)
        Self.spin { queries.cached(icon) != nil && item.submenu?.items.first?.image === queries.cached(icon) }
        #expect(item.submenu?.items.first?.image === queries.cached(icon))
        #expect(queries.cached(icon)?.size == NSSize(width: 16, height: 16))
        #expect(system.mainAsks.withLock { $0 } == 0)
    }

    @Test func theFileMenusOpenWithFillsFromTheKeptListInItsFirstTurn() async {
        let system = OpenWithWorkspace(apps: [Self.textEdit, Self.xcode], defaultApp: Self.textEdit)
        let apps = Self.apps(system)
        _ = await apps.openWithList(forFileNamed: "notes.txt", isDirectory: false)
        let menu = FileActionsMenu(apps: apps, mainWork: MainWorkScheduler(budget: MainFrameBudget()), actions: .init(openInCmux: { _ in }, revealInFiles: { _ in }))
        let row = menu.openWithItem(forFileNamed: "readme.txt") { nil }
        // Default, separator, Xcode, separator, Other…: no Loading row.
        #expect(row.submenu?.items.count == 5)
        #expect(row.submenu?.items.first?.isEnabled == true)
        #expect(system.mainAsks.withLock { $0 } == 0)
    }

    /// A cold Open With (no kept list) shows Loading, asks Launch Services off main, and fills the submenu
    /// in one posted userBlocking task when it answers (no main-actor task waits on it).
    @Test func theFileMenusColdOpenWithFillsWhenTheLaneAnswers() {
        let system = OpenWithWorkspace(apps: [Self.textEdit, Self.xcode], defaultApp: Self.textEdit)
        let apps = Self.apps(system)
        let menu = FileActionsMenu(apps: apps, mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                   actions: .init(openInCmux: { _ in }, revealInFiles: { _ in }))
        let row = menu.openWithItem(forFileNamed: "notes.txt") { nil }
        #expect(row.submenu?.items.count == 1, "a cold submenu shows only its Loading row")
        Self.spin { row.submenu?.items.count == 5 }
        // Default, separator, Xcode, separator, Other….
        #expect(row.submenu?.items.count == 5)
        #expect(system.mainAsks.withLock { $0 } == 0, "Launch Services was asked on the main thread")
    }

    @Test func theRowsOnScreenWarmOneListPerType() {
        let system = OpenWithWorkspace(apps: [Self.textEdit], defaultApp: Self.textEdit)
        let apps = Self.apps(system)
        let rows = (0..<200).map { (name: "file\($0).txt", isDirectory: false) } + [(name: "src", isDirectory: true)]
        apps.prefetchOpenWithLists(for: rows)
        Self.spin { apps.keptOpenWithList(forFileNamed: "src", isDirectory: true) != nil
            && apps.keptOpenWithList(forFileNamed: "x.txt", isDirectory: false) != nil }
        #expect(apps.keptOpenWithList(forFileNamed: "x.txt", isDirectory: false) != nil)
        // Two types (plain text, folder), each asked once: the app list and the default app.
        #expect(system.listAsks.withLock { $0 } == 2)
        #expect(system.mainAsks.withLock { $0 } == 0)
    }

    /// A path menu opened before Launch Services answered (a new file, a new type) draws Open in Text Editor and a
    /// Loading Open With, and both fill in when the lane answers, in the open menu. Before the fix the first menu had
    /// no editor row and only Other… under Open With, and nothing added them.
    @Test func aColdPathMenuGetsItsEditorAndAppsWhenTheLaneAnswers() throws {
        let system = OpenWithWorkspace(apps: [Self.textEdit, Self.xcode], defaultApp: Self.textEdit)
        let links = LinkMenu(queries: Self.queries(system))
        let file = URL(fileURLWithPath: "/tmp/p02-threads-056/notes.txt")
        let rows = links.pathRows(for: file, isDirectory: false)
        let openWith = try #require(rows.first { $0.kind == .openWith })
        let editorRow = try #require(rows.first { $0.kind == .openInTextEditor })
        #expect(openWith.waiting == .apps(file, isDirectory: false))
        #expect(openWith.children.first?.kind == .loading)
        #expect(editorRow.waiting == .editor)
        let menu = NSMenu()
        links.items(rows, file: file).forEach(menu.addItem)
        let openWithItem = try #require(menu.items.first { $0.title == openWith.title })
        let other = try #require(openWith.children.last?.title)
        Self.spin { Self.titles(openWithItem.submenu) == ["TextEdit", "Xcode", other] }
        #expect(Self.titles(openWithItem.submenu) == ["TextEdit", "Xcode", other])
        #expect(menu.items.contains { $0.title == editorRow.title }, "the editor row stays: the lane named an editor")
        let warm = links.pathRows(for: file, isDirectory: false)
        #expect(warm.first { $0.kind == .openInTextEditor }?.app == Self.textEdit)
        #expect(warm.allSatisfy { $0.waiting == nil })
        #expect(system.mainAsks.withLock { $0 } == 0)
    }

    /// With no editor and no app for the type, the waiting editor row leaves the open menu once the lane answers.
    @Test func aColdPathMenuDropsTheEditorRowWhenThereIsNone() throws {
        let system = OpenWithWorkspace(apps: [], defaultApp: nil)
        let links = LinkMenu(queries: Self.queries(system))
        let file = URL(fileURLWithPath: "/tmp/p02-threads-056/notes.txt")
        let rows = links.pathRows(for: file, isDirectory: false)
        let editorRow = try #require(rows.first { $0.kind == .openInTextEditor })
        let menu = NSMenu()
        links.items(rows, file: file).forEach(menu.addItem)
        Self.spin { !menu.items.contains { $0.title == editorRow.title } }
        #expect(!menu.items.contains { $0.title == editorRow.title })
    }

    /// A link menu opened before the browsers are kept shows Open In ▸ Loading, filled with the browsers once the
    /// lane answers.
    @Test func aColdLinkMenuFillsOpenInWhenTheLaneAnswers() throws {
        let system = OpenWithWorkspace(apps: [Self.textEdit, Self.xcode], defaultApp: Self.xcode)
        let links = LinkMenu(queries: Self.queries(system))
        let link = try #require(URL(string: "https://example.com/p02"))
        let rows = links.linkRows(for: link)
        let openIn = try #require(rows.first { $0.kind == .openIn })
        #expect(openIn.children.map(\.kind) == [.loading])
        let menu = NSMenu()
        links.items(rows, link: link).forEach(menu.addItem)
        let item = try #require(menu.items.first { $0.title == openIn.title })
        Self.spin { Self.titles(item.submenu) == ["Xcode", "TextEdit"] }
        #expect(Self.titles(item.submenu) == ["Xcode", "TextEdit"], "the default browser first")
    }

    /// An open of a URL no app handles fails the action's work, so a script or the CLI sees the failure. Before the fix
    /// a cold answer let the open go ahead and the action reported success, with only a late notice.
    @Test func anOpenWithNoHandlerFailsTheAction() async throws {
        let system = OpenWithWorkspace(apps: [], defaultApp: nil)
        let url = try #require(URL(string: "p02-threads-056-no-handler://example"))
        let failure = await AppActionContext.openWork(url, queries: Self.queries(system))()
        #expect(failure?.message == RefusalStrings.couldNotOpen(url.absoluteString))
        #expect(system.mainAsks.withLock { $0 } == 0)
    }

    /// `file open --where editor` with no editor on the Mac fails the action's work (it reported success before).
    @Test func anEditorOpenWithNoEditorFailsTheAction() async {
        let system = OpenWithWorkspace(apps: [], defaultApp: nil)
        let file = URL(fileURLWithPath: "/tmp/p02-threads-056/notes.txt")
        let failure = await AgentHandlers.editorWork(file, queries: Self.queries(system))()
        #expect(failure?.message == MiscHandlerStrings.noEditor)
        #expect(system.mainAsks.withLock { $0 } == 0)
    }
}

/// Launch Services from fixed answers: counts every question, the app-list questions and the ones asked on the main
/// thread.
nonisolated final class OpenWithWorkspace: WorkspaceQuerying {
    let apps: [URL]
    let defaultApp: URL?
    let asks = Mutex(0)
    let listAsks = Mutex(0)
    let mainAsks = Mutex(0)

    init(apps: [URL], defaultApp: URL?) {
        self.apps = apps
        self.defaultApp = defaultApp
    }

    private func ask<T>(_ answer: T) -> T {
        asks.withLock { $0 += 1 }
        if Thread.isMainThread { mainAsks.withLock { $0 += 1 } }
        return answer
    }

    func application(withBundleIdentifier bundleIdentifier: String) -> URL? { ask(nil) }
    func defaultApplication(toOpen url: URL) -> URL? { ask(defaultApp) }
    func defaultApplication(toOpen type: UTType) -> URL? { ask(defaultApp) }
    func applications(toOpen url: URL) -> [URL] { ask(apps) }

    func applications(toOpen type: UTType) -> [URL] {
        listAsks.withLock { $0 += 1 }
        return ask(apps)
    }

    func fileIcon(atPath path: String) -> NSImage { ask(NSImage(size: NSSize(width: 32, height: 32))) }
    func typeIcon(_ type: UTType) -> NSImage { ask(NSImage(size: NSSize(width: 32, height: 32))) }
}

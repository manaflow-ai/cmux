import AppKit
import CmuxNextActions
@testable import CmuxNextApp
#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
#else
import CmuxNextCompat
#endif
import CmuxNextFiles
import CmuxNextFilesUI
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
        let menu = FileExplorerOpenWithMenu(registry: ActionRegistry.standard(), appIcon: { app, item in apps.showIcon(of: app, in: item) })
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
        let menu = FileActionsMenu(apps: apps, actions: .init(openInCmux: { _ in }, revealInFiles: { _ in }))
        let row = menu.openWithItem(forFileNamed: "readme.txt") { nil }
        // Default, separator, Xcode, separator, Other…: no Loading row.
        #expect(row.submenu?.items.count == 5)
        #expect(row.submenu?.items.first?.isEnabled == true)
        #expect(system.mainAsks.withLock { $0 } == 0)
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

import AppKit
@testable import CmuxNextApp
import CmuxNextFiles
import CmuxNextFilesUI
import CmuxNextPages
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo, 2026-11-18: "we draw the visible area, right?". The Files tree and the Find results mount
/// only the rows in view, and a change to one item configures that item's row only: no change
/// reloads every row shown (``TableRows``).
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)))
struct FileExplorerRenderCountTests {
    /// A root of `count` files after one folder `a` (holding one file); `extra` adds a file.
    final class Lister: DirectoryListing, @unchecked Sendable {
        // Read and written on the main actor only (the model's calls), in this test.
        nonisolated(unsafe) var extra: String?
        nonisolated(unsafe) var lists = 0
        let count: Int
        let root: URL
        init(count: Int, root: URL) { (self.count, self.root) = (count, root) }
        func list(_ folder: URL) async throws -> [FileEntry] {
            lists += 1
            if folder.standardizedFileURL != root { return [FileEntry(name: "inside.txt", in: folder, kind: .file)] }
            let files = (1...count).map { FileEntry(name: String(format: "f%06d.txt", $0), in: folder, kind: .file) }
            return [FileEntry(name: "a", in: folder, kind: .folder)] + files + (extra.map { [FileEntry(name: $0, in: folder, kind: .file)] } ?? [])
        }
        func entry(at url: URL) async -> FileEntry? { nil }
    }

    nonisolated struct NoRepo: MarkdownGitRunning {
        func run(_ arguments: [String], in folder: String) async -> MarkdownGitOutput? { MarkdownGitOutput(status: 128, output: "") }
    }

    nonisolated struct NoWatch: FileTreeWatching {
        func changes(under folders: [URL]) -> AsyncStream<Void> { AsyncStream { _ in } }
    }

    /// What the fake ripgrep answers.
    @MainActor final class Answer {
        var matches: [RipgrepMatch]
        init(_ matches: [RipgrepMatch]) { self.matches = matches }
    }

    static func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    static func mounted(_ table: NSTableView) -> Int {
        var count = 0
        table.enumerateAvailableRowViews { _, _ in count += 1 }
        return count
    }

    static func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    @Test(arguments: [100, 10_000])
    func theTreeMountsTheViewportAndConfiguresOnlyChangedRows(count: Int) async throws {
        let root = URL(fileURLWithPath: "/tmp/render-count-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        let lister = Lister(count: count, root: root)
        let model = FileExplorerModel(lister: lister, git: NoRepo(), watcher: NoWatch(), isProtected: { _ in false })
        await model.setRoot(root)
        let view = FileExplorerSectionView(model: model, rootFolder: { nil }, perform: { _ in }, rowMenu: { _ in nil })
        let window = Self.window(view)
        defer { window.closeAfterTest() }
        // The view lists its root again when it shows; let that land.
        await Self.until { lister.lists >= 2 }
        for _ in 0..<20 { await Task.yield() }
        view.render()
        view.layoutSubtreeIfNeeded()
        let table = view.table
        let inView = table.rows(in: table.visibleRect).length
        let mounted = Self.mounted(table)
        print("render-count explorer N=\(count) viewport=\(inView) mounted=\(mounted)")
        #expect(inView > 0 && mounted > 0, "the tree mounted no rows")
        #expect(mounted <= inView * 3, "\(mounted) rows mounted for \(inView) in view at N=\(count)")

        // One new file near the top: its row only.
        let insert = await Self.counts(view.rows, view) {
            lister.extra = "f000000.txt"
            await model.reload()
            view.render()
        }
        print("render-count explorer N=\(count) one-insert configured=\(insert.configured) reloads=\(insert.reloads)")
        #expect(insert.configured == 1, "one new file configured \(insert.configured) rows at N=\(count)")
        #expect(insert.reloads == 0)

        // A relisting with nothing changed (the watcher, a refresh): no row.
        let relist = await Self.counts(view.rows, view) {
            await model.reload()
            view.render()
        }
        print("render-count explorer N=\(count) relist configured=\(relist.configured)")
        #expect(relist.configured == 0, "an unchanged relisting configured \(relist.configured) rows at N=\(count)")

        // Expanding a folder: its own row (the arrow) and its one child.
        let folder = try #require(model.rows.first { $0.isFolder })
        let expand = await Self.counts(view.rows, view) {
            await model.toggle(folder.url)
            view.render()
        }
        print("render-count explorer N=\(count) expand configured=\(expand.configured)")
        #expect(expand.configured == 2, "expanding configured \(expand.configured) rows at N=\(count)")

        // Selection moves: no row reconfigured.
        let select = await Self.counts(view.rows, view) {
            table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
            table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        }
        #expect(select.configured == 0)
        #expect(model.selection == model.rows[5].url)

        // One scroll step: the rows it reveals only.
        let scroll = await Self.counts(view.rows, view) {
            table.scroll(NSPoint(x: 0, y: table.visibleRect.minY + table.rowHeight + table.intercellSpacing.height))
        }
        print("render-count explorer N=\(count) scroll configured=\(scroll.configured) mounted=\(Self.mounted(table))")
        #expect(scroll.configured <= 2)
        #expect(Self.mounted(table) <= inView * 3)
    }

    /// The rows `rows` configured and the whole reloads it ran while `change` ran (and `view` laid out).
    static func counts<Row, ID>(_ rows: TableRows<Row, ID>, _ view: NSView,
                                _ change: () async -> Void) async -> (configured: Int, reloads: Int) {
        let configured = rows.configured, reloads = rows.fullReloads
        await change()
        view.layoutSubtreeIfNeeded()
        return (rows.configured - configured, rows.fullReloads - reloads)
    }

    @Test(arguments: [100, RipgrepSearch.limit])
    func findResultsConfigureOnlyChangedRows(count: Int) async throws {
        let matches = (1...count).map { RipgrepMatch(path: "/r/f\($0).swift", relativePath: "f\($0).swift", line: $0, column: 1, preview: "x \($0)") }
        let answer = Answer(matches)
        let model = FindSectionModel(search: { _, _ in .matches(answer.matches, limited: false) })
        let view = FindSectionView(model: model, rootFolder: { URL(fileURLWithPath: "/r") }, effects: NullFileExplorerEffects())
        let window = Self.window(view)
        defer { window.closeAfterTest() }
        await model.search("x")
        view.render()
        view.layoutSubtreeIfNeeded()
        let table = view.table
        let inView = table.rows(in: table.visibleRect).length
        let mounted = Self.mounted(table)
        print("render-count find N=\(count) viewport=\(inView) mounted=\(mounted)")
        #expect(inView > 0 && mounted > 0, "the results mounted no rows")
        #expect(mounted <= inView * 3)

        // The same search again (its searching state, then the same answer): no row.
        let same = await Self.counts(view.results, view) {
            await model.search("x")
            view.render()
        }
        print("render-count find N=\(count) same configured=\(same.configured)")
        #expect(same.configured == 0, "the same answer configured \(same.configured) rows at N=\(count)")

        // One result's line changed: its row only.
        let one = await Self.counts(view.results, view) {
            answer.matches[0] = RipgrepMatch(path: "/r/f1.swift", relativePath: "f1.swift", line: 1, column: 1, preview: "x changed")
            await model.search("x")
            view.render()
        }
        print("render-count find N=\(count) one-change configured=\(one.configured) reloads=\(one.reloads)")
        #expect(one.configured == 1, "one changed result configured \(one.configured) rows at N=\(count)")
        #expect(one.reloads == 0)

        // A narrower search drops one shown result: the row it reveals at the bottom only.
        let narrower = await Self.counts(view.results, view) {
            answer.matches.remove(at: 1)
            await model.search("x")
            view.render()
        }
        print("render-count find N=\(count) one-removed configured=\(narrower.configured)")
        #expect(narrower.configured <= 1, "dropping one result configured \(narrower.configured) rows at N=\(count)")
    }
}

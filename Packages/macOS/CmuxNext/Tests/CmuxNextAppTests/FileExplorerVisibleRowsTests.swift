import AppKit
@testable import CmuxNextApp
import CmuxNextFiles
import CmuxNextFilesUI
import CmuxNextPages
import CmuxNextTestSupport
import CmuxVisibleRows
import CmuxVisibleRowsTesting
import Foundation
import Testing

/// The Files tree and the Find results under the visible-rows contract (`VisibleRowsContract`), each at 100 and
/// 10,000 rows. Both are in `VisibleRowsBaseline` for one rule only: each update compares every row, since the
/// model hands over a whole new list.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct FileExplorerVisibleRowsTests {
    @Test func filesTree() async throws {
        try await VisibleRowsContract.check(FilesTreeRows.self)
    }

    @Test func findResults() async throws {
        try await VisibleRowsContract.check(FindResultRows.self)
    }
}

/// Lays the window out and draws it, as a display frame does.
@MainActor private func drawFrame(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
}

/// One table row down from the middle of `table` (that first move is not measured).
@MainActor private func scrollTableOneRow(_ table: NSTableView, _ list: some VisibleRowsList, _ window: NSWindow) -> Bool {
    guard let clip = table.enclosingScrollView?.contentView else { return false }
    let maxY = max(0, table.frame.height - clip.bounds.height)
    guard maxY > 0 else { return false }
    clip.scroll(to: NSPoint(x: 0, y: min(maxY / 2, 2_000)))
    table.enclosingScrollView?.reflectScrolledClipView(clip)
    drawFrame(window)
    _ = list.listWork.take()
    clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + table.rowHeight + table.intercellSpacing.height))
    table.enclosingScrollView?.reflectScrolledClipView(clip)
    drawFrame(window)
    return true
}

@MainActor private func makeWindow(_ view: NSView) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 400), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderFrontRegardless()
    drawFrame(window)
    return window
}

/// The Files tree over a root of `rows` files; a file's git state changes as one item's change.
@MainActor final class FilesTreeRows: VisibleRowsFixture {
    static let name = "files tree"

    /// `rows` files in the root, listed without the disk.
    final class Lister: DirectoryListing, @unchecked Sendable {
        // Read and written on the main actor only (the model's calls), in this test.
        nonisolated(unsafe) var lists = 0
        let count: Int
        init(count: Int) { self.count = count }
        func list(_ folder: URL) async throws -> [FileEntry] {
            lists += 1
            return (1...count).map { FileEntry(name: String(format: "f%06d.txt", $0), in: folder, kind: .file) }
        }
        func entry(at url: URL) async -> FileEntry? { nil }
    }

    /// `git` at the root whose status the fixture changes.
    final class Git: MarkdownGitRunning, @unchecked Sendable {
        // Read and written on the main actor only (the model's calls), in this test.
        nonisolated(unsafe) var status = ""
        let top: String
        init(top: String) { self.top = top }
        func run(_ arguments: [String], in folder: String) async -> MarkdownGitOutput? {
            MarkdownGitOutput(status: 0, output: arguments.first == "rev-parse" ? top : status)
        }
    }

    nonisolated struct NoWatch: FileTreeWatching {
        func changes(under folders: [URL]) -> AsyncStream<Void> { AsyncStream { _ in } }
    }

    let root: URL
    let lister: Lister
    let git: Git
    let model: FileExplorerModel
    let list: FileExplorerSectionView
    let window: NSWindow

    init(rows: Int) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visible-rows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        lister = Lister(count: rows)
        git = Git(top: root.path)
        model = FileExplorerModel(lister: lister, git: git, watcher: NoWatch(), isProtected: { _ in false })
        await model.setRoot(root)
        list = FileExplorerSectionView(model: model, rootFolder: { nil }, perform: { _ in }, rowMenu: { _ in nil })
        window = makeWindow(list)
        // The view lists its root again when it shows; let that land.
        for _ in 0..<400 where lister.lists < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<20 { await Task.yield() }
        list.render()
        drawFrame(window)
    }

    var viewportRows: Int { list.table.rows(in: list.table.visibleRect).length }

    /// A shown file turns untracked (an editor saved a new file): its git letter changes.
    func changeOneItem() async throws {
        git.status = "?? f000003.txt\0"
        await model.reload()
        list.render()
        drawFrame(window)
    }

    func scrollOneRow() async throws -> Bool { scrollTableOneRow(list.table, list, window) }

    /// One live-resize step of the window: 8 pt narrower.
    func resizeOneStep() async throws -> Bool {
        window.setContentSize(NSSize(width: 252, height: 400))
        drawFrame(window)
        return true
    }

    func close() {
        window.close()
        try? FileManager.default.removeItem(at: root)
    }
}

/// The Find results over `rows` matches; one match's line changes as one item's change.
@MainActor final class FindResultRows: VisibleRowsFixture {
    static let name = "find results"

    /// What the fake ripgrep answers.
    @MainActor final class Answer {
        var matches: [RipgrepMatch]
        init(_ matches: [RipgrepMatch]) { self.matches = matches }
    }

    let answer: Answer
    let model: FindSectionModel
    let list: FindSectionView
    let window: NSWindow

    init(rows: Int) async throws {
        let answer = Answer((1...rows).map {
            RipgrepMatch(path: "/r/f\($0).swift", relativePath: "f\($0).swift", line: $0, column: 1, preview: "x \($0)")
        })
        self.answer = answer
        model = FindSectionModel(search: { _, _ in .matches(answer.matches, limited: false) })
        list = FindSectionView(model: model, rootFolder: { URL(fileURLWithPath: "/r") }, effects: NullFileExplorerEffects())
        window = makeWindow(list)
        await model.search("x")
        list.render()
        drawFrame(window)
    }

    var viewportRows: Int { list.table.rows(in: list.table.visibleRect).length }

    /// The file under a shown match changed: the same search answers that match with a new line.
    func changeOneItem() async throws {
        answer.matches[2] = RipgrepMatch(path: "/r/f3.swift", relativePath: "f3.swift", line: 3, column: 1, preview: "x changed")
        await model.search("x")
        list.render()
        drawFrame(window)
    }

    func scrollOneRow() async throws -> Bool { scrollTableOneRow(list.table, list, window) }

    /// One live-resize step of the window: 8 pt narrower.
    func resizeOneStep() async throws -> Bool {
        window.setContentSize(NSSize(width: 252, height: 400))
        drawFrame(window)
        return true
    }

    func close() { window.close() }
}

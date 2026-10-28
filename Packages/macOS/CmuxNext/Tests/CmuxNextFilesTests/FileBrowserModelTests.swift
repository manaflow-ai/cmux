import Foundation
import Testing
@testable import CmuxNextFiles
import CmuxNextWakeups

/// The pane model over a real temp folder: listing, filters, selection and
/// keyboard moves, history, Go to Folder, and changes with Undo and Redo.
@MainActor
struct FileBrowserModelTests {
    private func model(_ temp: TempFolder, watcher: any FolderWatching = ManualWatcher(), now: @escaping @Sendable () -> Date = { Date() }) -> FileBrowserModel {
        FileBrowserModel(folder: temp.url, work: MainWorkScheduler(budget: MainFrameBudget()), watcher: watcher, resolver: GoToFolderResolver(home: temp.url), now: now)
    }

    @Test func listsSortedAndHidesHiddenUntilAsked() async throws {
        let temp = try TempFolder()
        for name in ["b", "a", "C", ".hidden"] { try temp.file(name) }
        let model = model(temp)
        await model.reload()
        #expect(model.phase == .ready)
        #expect(model.entries.map(\.name) == ["a", "b", "C"])
        model.showHidden = true
        #expect(model.entries.map(\.name) == [".hidden", "a", "b", "C"])
        model.filterText = "c"
        #expect(model.entries.map(\.name) == ["C"])
    }

    @Test func keyboardMovesAndShiftExtends() async throws {
        let temp = try TempFolder()
        for name in ["a", "b", "c", "d"] { try temp.file(name) }
        let model = model(temp)
        await model.reload()
        model.moveCursor(by: 1)
        #expect(model.selection == ["a"])
        model.moveCursor(by: 1, extending: true)
        #expect(model.selection == ["a", "b"])
        model.moveCursorToEdge(last: true)
        #expect(model.selection == ["d"])
        model.extend(to: "b")
        #expect(model.selection == ["b", "c", "d"])
        model.toggle("c")
        #expect(model.selection == ["b", "d"])
        model.selectAll()
        #expect(model.selection.count == 4)
    }

    @Test func typeSelectBuildsAPrefixUntilAPause() async throws {
        let temp = try TempFolder()
        for name in ["apple", "banana", "berry", "cherry"] { try temp.file(name) }
        let clock = FakeClock()
        let model = model(temp, now: { clock.now })
        await model.reload()
        model.typeSelect("b")
        #expect(model.selection == ["banana"])
        model.typeSelect("e")
        #expect(model.selection == ["berry"])
        clock.advance(2)
        model.typeSelect("c")
        #expect(model.selection == ["cherry"])
        clock.advance(2)
        model.typeSelect("bz")
        #expect(model.selection == ["cherry"]) // nearest after "bz"
    }

    @Test func historyAndEnclosingFolder() async throws {
        let temp = try TempFolder()
        let sub = try temp.folder("sub")
        try temp.file("inner", in: "sub")
        let model = model(temp)
        await model.reload()
        let entry = try #require(model.entries.first { $0.name == "sub" })
        #expect(await model.activate(entry) == .openedFolder(entry.url))
        #expect(model.folder.path == sub.path)
        #expect(model.entries.map(\.name) == ["inner"])
        await model.goBack()
        #expect(model.folder.path == temp.url.path)
        #expect(model.selection == ["sub"])
        await model.goForward()
        #expect(model.folder.path == sub.path)
        await model.goUp()
        #expect(model.folder.path == temp.url.path)
        #expect(model.selection == ["sub"])
    }

    @Test func goToFolderAcceptsTildeRelativeAndFilePaths() async throws {
        let temp = try TempFolder()
        try temp.folder("deep")
        try temp.file("note.md", in: "deep")
        let model = model(temp)
        await model.reload()
        #expect(await model.goTo("~/deep"))
        #expect(model.folder.lastPathComponent == "deep")
        #expect(await model.goTo("\(temp.url.path)/deep/note.md"))
        #expect(model.selection == ["note.md"])
        #expect(!(await model.goTo("nope-\(UUID().uuidString)")))
        #expect(model.lastError != nil)
    }

    @Test func activatingAFileIsForTheHost() async throws {
        let temp = try TempFolder()
        let file = try temp.file("doc.txt")
        let model = model(temp)
        await model.reload()
        #expect(await model.activate(model.entries[0]) == .openFile(file))
    }

    @Test func trashUndoRedo() async throws {
        let temp = try TempFolder()
        try temp.file("keep")
        try temp.file("toss")
        let model = model(temp)
        await model.reload()
        model.select("toss")
        await model.trashSelection()
        #expect(model.entries.map(\.name) == ["keep"])
        #expect(model.canUndo)
        await model.undo()
        #expect(model.entries.map(\.name) == ["keep", "toss"])
        #expect(model.canRedo)
        await model.redo()
        #expect(model.entries.map(\.name) == ["keep"])
        await model.undo()
        #expect(temp.names() == ["keep", "toss"])
    }

    @Test func renameNewFolderDuplicateWithUndo() async throws {
        let temp = try TempFolder()
        try temp.file("draft.txt")
        let model = model(temp)
        await model.reload()
        let renamed = await model.rename(temp.url.appendingPathComponent("draft.txt"), to: "final.txt")
        #expect(renamed?.lastPathComponent == "final.txt")
        #expect(model.selection == ["final.txt"])
        await model.undo()
        #expect(temp.names() == ["draft.txt"])
        let folder = await model.newFolder(named: "untitled folder")
        #expect(folder?.lastPathComponent == "untitled folder")
        #expect(model.selection == ["untitled folder"])
        await model.undo()
        #expect(temp.names() == ["draft.txt"])
        model.select("draft.txt")
        await model.duplicateSelection()
        #expect(model.selection == ["draft copy.txt"])
        #expect(temp.names() == ["draft.txt", "draft copy.txt"])
        await model.undo()
        #expect(temp.names() == ["draft.txt"])
        #expect(await model.rename(temp.url.appendingPathComponent("draft.txt"), to: "") == nil)
        #expect(model.lastError == .invalidName(""))
    }

    @Test func dropCopiesInWithUndo() async throws {
        let temp = try TempFolder()
        let outside = try TempFolder()
        let source = try outside.file("photo.png", bytes: 100)
        let model = model(temp)
        await model.reload()
        await model.transfer([source], mode: .copy, resolve: { _ in ConflictAnswer(.stop) })
        #expect(model.entries.map(\.name) == ["photo.png"])
        #expect(model.selection == ["photo.png"])
        #expect(model.transferProgress == nil)
        await model.undo()
        #expect(temp.names().isEmpty)
        #expect(outside.names() == ["photo.png"])
    }

    @Test func watchedChangesUpdateRowsWithoutAFullListing() async throws {
        let temp = try TempFolder()
        try temp.file("old")
        let watcher = ManualWatcher()
        let model = model(temp, watcher: watcher)
        await model.reload()
        try temp.file("new")
        try FileManager.default.removeItem(at: temp.url.appendingPathComponent("old"))
        await model.apply(.items(["new", "old"]), in: model.folder)
        #expect(model.entries.map(\.name) == ["new"])
    }
}

/// A clock tests move by hand.
// Written only by the test body and read only by the model, both on the main actor.
private final class FakeClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now += seconds }
}

/// A watcher that never yields on its own (tests call `apply` directly).
private struct ManualWatcher: FolderWatching {
    func changes(in folder: URL) -> AsyncStream<FolderChange> { AsyncStream { _ in } }
}

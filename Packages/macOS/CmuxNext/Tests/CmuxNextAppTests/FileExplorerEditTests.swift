import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextFiles
import Foundation
import Testing
import CmuxNextFilesUI

/// The Files tree makes, renames and trashes items (classic's file explorer menu: New File, New
/// Folder, Rename, Move to Trash) and shows each item's git state.
@MainActor @Suite(.serialized)
struct FileExplorerEditTests {
    /// The real operator, except that Move to Trash deletes (a test leaves nothing in the Trash).
    struct DeletingTrash: FileOperating {
        let real = FileOperator()
        let trashed = TrashLog()
        func rename(_ url: URL, to name: String) async throws -> URL { try await real.rename(url, to: name) }
        func newFolder(in folder: URL, named name: String) async throws -> URL { try await real.newFolder(in: folder, named: name) }
        func duplicate(_ urls: [URL]) async throws -> [URL] { try await real.duplicate(urls) }
        func trash(_ urls: [URL]) async throws -> [TrashedItem] {
            for url in urls { try FileManager.default.removeItem(at: url) }
            await trashed.add(urls)
            return urls.map { TrashedItem(original: $0, trashed: $0) }
        }
        func putBack(_ items: [TrashedItem]) async throws -> [URL] { [] }
        func move(_ pairs: [(from: URL, to: URL)]) async throws { try await real.move(pairs) }
        func transfer(_ sources: [URL], to folder: URL, mode: TransferMode,
                      resolve: @escaping @Sendable (FileConflict) async -> ConflictAnswer) -> AsyncThrowingStream<TransferEvent, any Error> {
            real.transfer(sources, to: folder, mode: mode, resolve: resolve)
        }
        func makeLinks(_ urls: [URL], kind: LinkKind) async throws -> [URL] { try await real.makeLinks(urls, kind: kind) }
        func deleteImmediately(_ urls: [URL]) async throws { try await real.deleteImmediately(urls) }
        func compress(_ urls: [URL], archiveName: String) async throws -> URL { try await real.compress(urls, archiveName: archiveName) }
        func expand(_ archive: URL) async throws -> URL { try await real.expand(archive) }
    }

    actor TrashLog {
        private(set) var urls: [URL] = []
        func add(_ more: [URL]) { urls += more }
    }

    /// `git` answering for a repository at the tree's root.
    struct FakeGit: MarkdownGitRunning {
        let top: String
        let porcelain: String
        func run(_ arguments: [String], in folder: String) async -> MarkdownGitOutput? {
            switch arguments.first {
            case "rev-parse": MarkdownGitOutput(status: 0, output: top + "\n")
            case "status": MarkdownGitOutput(status: 0, output: porcelain)
            default: nil
            }
        }
    }

    static func names(_ model: FileExplorerModel) -> [String] { model.rows.map(\.name) }

    static func setUp() async throws -> (FileExplorerModel, FileExplorerCommands, DeletingTrash) {
        let root = try FileExplorerTests.folder()
        let model = FileExplorerModel(git: FakeGit(top: "/nowhere", porcelain: ""))
        await model.setRoot(root)
        let files = DeletingTrash()
        return (model, FileExplorerCommands(model: model, effects: FileExplorerTests.Recorder(), files: files), files)
    }

    @Test func newFileAndNewFolderMakeUntitledItemsAndSelectThem() async throws {
        let (model, commands, _) = try await Self.setUp()
        let file = try await commands.newFile()
        #expect(file.lastPathComponent == FileExplorerStrings.untitledFile)
        #expect(model.selection == file.standardizedFileURL)
        #expect(try await commands.newFile().lastPathComponent == FileExplorerStrings.untitledFile + " 2")
        model.selection = try #require(model.rows.first { $0.name == "Sources" }).url
        let folder = try await commands.newFolder()
        #expect(folder.deletingLastPathComponent().lastPathComponent == "Sources", "a folder selected: the new item goes in it")
        #expect(model.row(folder.standardizedFileURL) != nil, "the folder expanded to show the new item")
        #expect(Self.names(model).contains(FileExplorerStrings.untitledFolder))
    }

    @Test func renameRenamesTheItemAndKeepsItSelected() async throws {
        let (model, commands, _) = try await Self.setUp()
        let readme = try #require(model.rows.first { $0.name == "README.md" }).url
        let renamed = try await commands.rename(readme, to: "NOTES.md")
        #expect(Self.names(model).contains("NOTES.md") && !Self.names(model).contains("README.md"))
        #expect(model.selection == renamed.standardizedFileURL)
        await #expect(throws: FileBrowserError.self) { try await commands.rename(renamed, to: "b.txt") }
    }

    @Test func moveToTrashTrashesTheSelectionAndTheRowGoes() async throws {
        let (model, commands, files) = try await Self.setUp()
        let b = try #require(model.rows.first { $0.name == "b.txt" }).url
        model.selection = b
        try await commands.moveToTrash()
        #expect(await files.trashed.urls == [b])
        #expect(!Self.names(model).contains("b.txt"))
        #expect(model.selection == nil)
    }

    /// Move to Trash into a temp "Trash" folder; Put Back moves each item back.
    struct FolderTrash: FileOperating {
        let real = FileOperator()
        let bin: URL
        func rename(_ url: URL, to name: String) async throws -> URL { try await real.rename(url, to: name) }
        func newFolder(in folder: URL, named name: String) async throws -> URL { try await real.newFolder(in: folder, named: name) }
        func duplicate(_ urls: [URL]) async throws -> [URL] { try await real.duplicate(urls) }
        func trash(_ urls: [URL]) async throws -> [TrashedItem] {
            try urls.map { url in
                let target = bin.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: target)
                return TrashedItem(original: url, trashed: target)
            }
        }
        func putBack(_ items: [TrashedItem]) async throws -> [URL] {
            try items.map { item in
                try FileManager.default.moveItem(at: item.trashed, to: item.original)
                return item.original
            }
        }
        func move(_ pairs: [(from: URL, to: URL)]) async throws { try await real.move(pairs) }
        func transfer(_ sources: [URL], to folder: URL, mode: TransferMode,
                      resolve: @escaping @Sendable (FileConflict) async -> ConflictAnswer) -> AsyncThrowingStream<TransferEvent, any Error> {
            real.transfer(sources, to: folder, mode: mode, resolve: resolve)
        }
        func makeLinks(_ urls: [URL], kind: LinkKind) async throws -> [URL] { try await real.makeLinks(urls, kind: kind) }
        func deleteImmediately(_ urls: [URL]) async throws { try await real.deleteImmediately(urls) }
        func compress(_ urls: [URL], archiveName: String) async throws -> URL { try await real.compress(urls, archiveName: archiveName) }
        func expand(_ archive: URL) async throws -> URL { try await real.expand(archive) }
    }

    /// Cmd-Z (Edit > Undo on the window's undo stack) after Move to Trash puts the file back.
    @Test(.timeLimit(.minutes(1))) func undoPutsATrashedFileBack() async throws {
        let root = try FileExplorerTests.folder()
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let model = FileExplorerModel(git: FakeGit(top: "/nowhere", porcelain: ""))
        await model.setRoot(root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        let undo = try #require(window.undoManager)
        let commands = FileExplorerCommands(model: model, effects: FileExplorerTests.Recorder(), files: FolderTrash(bin: bin), undoManager: undo)
        let b = try #require(model.rows.first { $0.name == "b.txt" }).url
        model.selection = b
        try await commands.moveToTrash()
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(undo.canUndo)
        #expect(undo.undoActionName == FileExplorerStrings.undoMoveToTrash)
        undo.undo()
        for await names in ObservationStream({ model.rows.map(\.name) }) where names.contains("b.txt") { break }
        #expect(FileManager.default.fileExists(atPath: b.path))
    }

    @Test func eachRowShowsItsGitStateAndAFolderShowsChangesInside() async throws {
        let root = try FileExplorerTests.folder()
        let top = root.resolvingSymlinksInPath().path
        let model = FileExplorerModel(git: FakeGit(top: top, porcelain: " M Sources/App.swift\0?? b.txt\0A  README.md\0"))
        await model.setRoot(root)
        await model.toggle(try #require(model.rows.first { $0.name == "Sources" }).url)
        func state(_ name: String) -> FileGitState? { model.rows.first { $0.name == name }?.git }
        #expect(state("App.swift") == .modified)
        #expect(state("b.txt") == .untracked)
        #expect(state("README.md") == .added)
        #expect(state("Sources") == .containsChanges)
    }

    @Test func outsideARepositoryNoRowHasAGitState() async throws {
        let root = try FileExplorerTests.folder()
        struct NoRepo: MarkdownGitRunning {
            func run(_ arguments: [String], in folder: String) async -> MarkdownGitOutput? { MarkdownGitOutput(status: 128, output: "") }
        }
        let model = FileExplorerModel(git: NoRepo())
        await model.setRoot(root)
        #expect(model.rows.allSatisfy { $0.git == nil })
    }

    @Test func porcelainParsesRenamesAndConflicts() {
        let states = FileGitState.parse("R  new.txt\0old.txt\0UU both.txt\0 D gone.txt\0")
        #expect(states == ["new.txt": .renamed, "both.txt": .conflicted, "gone.txt": .deleted])
    }
}

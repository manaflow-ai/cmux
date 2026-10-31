import AppKit
import CmuxNextFileGrid
import CmuxNextFiles
@testable import CmuxNextScreenshots
import Foundation
import Testing

/// The pane's file commands: open and reveal through the app, rename and trash through
/// CmuxNextFiles' operations, each undoable.
@MainActor @Suite struct ScreenshotsCommandsTests {
    static func item(_ url: URL) -> FileGridItem {
        FileGridItem(url: url, size: 4, modified: Date(), sourceID: "s")
    }

    @Test func openAndRevealGoToTheWorkspace() {
        let workspace = RecordingWorkspace()
        let files = RecordingFiles()
        let commands = ScreenshotsCommands(workspace: workspace, files: files)
        let shot = Self.item(URL(fileURLWithPath: "/s/a.png"))
        commands.perform(.open, on: [shot], in: nil)
        commands.perform(.reveal, on: [shot], in: nil)
        #expect(workspace.opened == [shot.url])
        #expect(workspace.revealed == [shot.url])
    }

    @Test func renameGoesThroughFilesAndUndoes() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("a.png")
        let undo = UndoManager()
        undo.groupsByEvent = false
        let commands = ScreenshotsCommands(workspace: RecordingWorkspace(), files: FileOperator())
        undo.beginUndoGrouping()
        let renamed = try await commands.rename(Self.item(file), to: "b.png", undo: undo)
        undo.endUndoGrouping()
        #expect(renamed.lastPathComponent == "b.png")
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        undo.undo()
        try await commands.pendingUndo?.value
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: renamed.path))
    }

    @Test func renameRefusesATakenName() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("a.png")
        try folder.write("b.png")
        let commands = ScreenshotsCommands(workspace: RecordingWorkspace(), files: FileOperator())
        await #expect(throws: FileBrowserError.self) { try await commands.rename(Self.item(file), to: "b.png", undo: nil) }
    }

    /// Issue #24760: Rename's sheet crashed the app with "beginSheetModalForWindow may only be
    /// invoked from the main thread" (the sheet was begun from an `async let` child task). The
    /// sheet must begin on the main thread, and answering it renames the file. The window answers
    /// the sheet itself (``AnsweringWindow``), so the test needs no WindowServer.
    @Test(.timeLimit(.minutes(1))) func renameSheetBeginsOnTheMainThreadAndRenames() async throws {
        _ = NSApplication.shared
        let folder = try TemporaryFolder()
        let file = try folder.write("a.png")
        let window = AnsweringWindow(newName: "b.png")
        defer { window.close() }
        let commands = ScreenshotsCommands(workspace: RecordingWorkspace(), files: FileOperator())

        commands.perform(.rename, on: [Self.item(file)], in: window)
        await commands.pendingRename?.value

        #expect(window.sheetsBeganOnMain == [true], "the rename sheet must begin once, on the main thread")
        #expect(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("b.png").path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// Move to Trash runs the Files operation (no real Trash in a test) and Undo puts the items back.
    @Test func trashGoesThroughFilesAndUndoPutsBack() async throws {
        let files = RecordingFiles()
        let commands = ScreenshotsCommands(workspace: RecordingWorkspace(), files: files)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let shot = Self.item(URL(fileURLWithPath: "/s/a.png"))
        undo.beginUndoGrouping()
        try await commands.trash([shot], undo: undo)
        undo.endUndoGrouping()
        #expect(await files.trashed == [shot.url])
        undo.undo()
        try await commands.pendingUndo?.value
        #expect(await files.putBack == [shot.url])
    }
}

/// A window that answers each sheet at once: it types `newName` into the sheet's text field and
/// presses the first button. NSAlert's `beginSheetModal(for:)` begins its sheet through
/// `beginSheet(_:completionHandler:)`, so this records the thread each sheet began on.
@MainActor final class AnsweringWindow: NSWindow {
    private let newName: String
    private(set) var sheetsBeganOnMain: [Bool] = []

    init(newName: String) {
        self.newName = newName
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    override func beginSheet(_ sheet: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        sheetsBeganOnMain.append(Thread.isMainThread)
        Self.textField(in: sheet.contentView)?.stringValue = newName
        completionHandler?(.alertFirstButtonReturn)
    }

    private static func textField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews { if let found = textField(in: child) { return found } }
        return nil
    }
}

/// Records opens and reveals.
@MainActor final class RecordingWorkspace: ScreenshotsWorkspace {
    var opened: [URL] = []
    var revealed: [URL] = []
    func open(_ urls: [URL]) { opened += urls }
    func reveal(_ urls: [URL]) { revealed += urls }
}

/// Records trash and put back; every other operation is refused.
actor RecordingFiles: FileOperating {
    var trashed: [URL] = []
    var putBack: [URL] = []

    func trash(_ urls: [URL]) async throws -> [TrashedItem] {
        trashed += urls
        return urls.map { TrashedItem(original: $0, trashed: URL(fileURLWithPath: "/.Trash").appendingPathComponent($0.lastPathComponent)) }
    }

    func putBack(_ items: [TrashedItem]) async throws -> [URL] {
        putBack += items.map(\.original)
        return items.map(\.original)
    }

    func rename(_ url: URL, to name: String) async throws -> URL { throw FileBrowserError.cancelled }
    func newFolder(in folder: URL, named name: String) async throws -> URL { throw FileBrowserError.cancelled }
    func duplicate(_ urls: [URL]) async throws -> [URL] { throw FileBrowserError.cancelled }
    func move(_ pairs: [(from: URL, to: URL)]) async throws { throw FileBrowserError.cancelled }
    nonisolated func transfer(_ sources: [URL], to folder: URL, mode: TransferMode,
                              resolve: @escaping @Sendable (FileConflict) async -> ConflictAnswer)
        -> AsyncThrowingStream<TransferEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: FileBrowserError.cancelled) }
    }
    func makeLinks(_ urls: [URL], kind: LinkKind) async throws -> [URL] { throw FileBrowserError.cancelled }
    func deleteImmediately(_ urls: [URL]) async throws { throw FileBrowserError.cancelled }
    func compress(_ urls: [URL], archiveName: String) async throws -> URL { throw FileBrowserError.cancelled }
    func expand(_ archive: URL) async throws -> URL { throw FileBrowserError.cancelled }
}

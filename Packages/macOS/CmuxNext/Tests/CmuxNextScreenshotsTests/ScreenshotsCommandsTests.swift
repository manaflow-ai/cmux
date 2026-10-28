import AppKit
import CmuxNextDesign
import CmuxNextFileGrid
import CmuxNextFiles
@testable import CmuxNextScreenshots
import Foundation
import Testing
import CmuxNextWakeups

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
        let commands = ScreenshotsCommands(workspace: RecordingWorkspace(), files: FileOperator(work: BackgroundWork()))
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
        let commands = ScreenshotsCommands(workspace: RecordingWorkspace(), files: FileOperator(work: BackgroundWork()))
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
        let commands = ScreenshotsCommands(workspace: RecordingWorkspace(), files: FileOperator(work: BackgroundWork()))

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

    /// A pane in no window never spins a nested modal loop (`runModal`). Rename has
    /// no sheet to show, so it asks nothing and renames nothing.
    @Test(.timeLimit(.minutes(1))) func renameInNoWindowAsksNothing() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("a.png")
        let dialogs = CmuxDialogCenter(host: SilentDialogHost())
        let commands = ScreenshotsCommands(workspace: RecordingWorkspace(), files: FileOperator(work: BackgroundWork()), dialogs: dialogs)

        commands.perform(.rename, on: [Self.item(file)], in: nil)
        await commands.pendingRename?.value

        #expect(dialogs.records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// A failed Move to Trash in no window says so in an app-scope cmux dialog
    /// that nothing waits for, not in an app-modal alert loop.
    @Test(.timeLimit(.minutes(1))) func trashFailureInNoWindowShowsAnAppDialog() async {
        let dialogs = CmuxDialogCenter(host: SilentDialogHost())
        let commands = ScreenshotsCommands(workspace: RecordingWorkspace(), files: RecordingFiles(trashError: .failed("disk gone")),
                                           dialogs: dialogs)
        let shot = Self.item(URL(fileURLWithPath: "/s/a.png"))

        let opened: CmuxDialogCenter.Record = await withCheckedContinuation { continuation in
            var resumed = false
            _ = dialogs.observe { event in
                guard case .opened(let record) = event, !resumed else { return }
                resumed = true
                continuation.resume(returning: record)
            }
            commands.perform(.trash, on: [shot], in: nil)
        }

        #expect(opened.scope == "app")
        #expect(opened.spec.identifier == "cmux.dialog.screenshots.message")
        #expect(opened.spec.buttons.map(\.id) == ["ok"])
    }
}

/// Places no dialog: the tests read the center's records.
@MainActor final class SilentDialogHost: CmuxDialogHosting {
    func show(_ dialog: CmuxDialogView, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {}
    func hide(_ dialog: CmuxDialogView) {}
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

/// Records trash and put back (trash fails with `trashError` when set); every other operation is refused.
actor RecordingFiles: FileOperating {
    var trashed: [URL] = []
    var putBack: [URL] = []
    private let trashError: FileBrowserError?

    init(trashError: FileBrowserError? = nil) {
        self.trashError = trashError
    }

    func trash(_ urls: [URL]) async throws -> [TrashedItem] {
        if let trashError { throw trashError }
        trashed += urls
        return urls.map { TrashedItem(original: $0, trashed: URL(fileURLWithPath: "/.Trash").appendingPathComponent($0.lastPathComponent)) }
    }

    func putBack(_ items: [TrashedItem]) async throws -> [URL] {
        putBack += items.map(\.original)
        return items.map(\.original)
    }

    func rename(_ url: URL, to name: String) async throws -> URL { throw FileBrowserError.cancelled }
    func newFolder(in folder: URL, named name: String) async throws -> URL { throw FileBrowserError.cancelled }
    func newFile(in folder: URL, named name: String, contents: Data) async throws -> URL { throw FileBrowserError.cancelled }
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

public import AppKit
public import CmuxNextFileGrid
public import CmuxNextFiles

/// Runs a grid command on the pane's files: the one path the grid's menu,
/// keys and double click reach. Open and reveal go to the app; rename and
/// Move to Trash go through CmuxNextFiles' ``FileOperating`` and register
/// Undo (move back, Put Back) on the window's undo manager, as the Files
/// pane does. Nothing is mirrored into the listing: the folder watch sees
/// the disk change.
@MainActor
public final class ScreenshotsCommands {
    private let workspace: any ScreenshotsWorkspace
    private let files: any FileOperating
    private let pasteboard: NSPasteboard
    private let writer: FileGridPasteboard
    /// The last Undo's file operation (tests wait on it).
    private(set) var pendingUndo: Task<Void, any Error>?
    /// The open Rename sheet and its rename (tests wait on it).
    private(set) var pendingRename: Task<Void, Never>?

    /// Makes the commands.
    ///
    /// - Parameters:
    ///   - workspace: opens and reveals (the app's off-main implementation).
    ///   - files: renames and trashes (CmuxNextFiles).
    ///   - pasteboard: Copy's pasteboard (default: the general one).
    ///   - writer: what Copy writes.
    public init(workspace: any ScreenshotsWorkspace, files: any FileOperating, pasteboard: NSPasteboard = .general,
                writer: FileGridPasteboard = FileGridPasteboard()) {
        self.workspace = workspace
        self.files = files
        self.pasteboard = pasteboard
        self.writer = writer
    }

    /// Runs `command` on `items`; sheets, errors and Undo attach to `window`.
    ///
    /// - Parameters:
    ///   - command: what to do.
    ///   - items: the selected files.
    ///   - window: the pane's window.
    public func perform(_ command: FileGridCommand, on items: [FileGridItem], in window: NSWindow?) {
        guard command.applies(toSelectionOf: items.count) else { return }
        switch command {
        case .open: workspace.open(items.map(\.url))
        case .quickLook: break
        case .reveal: workspace.reveal(items.map(\.url))
        case .copy: writer.write(items, to: pasteboard)
        case .copyPath: writer.writePaths(items, to: pasteboard)
        case .rename:
            guard let item = items.first else { return }
            // task-owner: `pendingRename`; one rename sheet; ends when the person answers it
            pendingRename = Task { await askToRename(item, in: window) }
        case .trash:
            // task-owner: one Move to Trash; ends when the files are moved
            Task {
                do { try await trash(items, undo: window?.undoManager) } catch { show(error, in: window) }
            }
        }
    }

    /// Renames the file and registers Undo (rename back).
    ///
    /// - Parameters:
    ///   - item: the file.
    ///   - name: the new name.
    ///   - undo: the window's undo manager, if any.
    /// - Returns: the renamed file.
    /// - Throws: ``FileBrowserError`` (invalid or taken name, failure).
    @discardableResult
    public func rename(_ item: FileGridItem, to name: String, undo: UndoManager?) async throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != item.name else { return item.url }
        let target = try await files.rename(item.url, to: trimmed)
        registerUndo(on: undo) { files in try await files.move([(from: target, to: item.url)]) }
        return target
    }

    /// Moves the files to the Trash and registers Undo (Put Back).
    ///
    /// - Parameters:
    ///   - items: the files.
    ///   - undo: the window's undo manager, if any.
    public func trash(_ items: [FileGridItem], undo: UndoManager?) async throws {
        let trashed = try await files.trash(items.map(\.url))
        registerUndo(on: undo) { files in _ = try await files.putBack(trashed) }
    }

    private func registerUndo(on undo: UndoManager?, _ operation: @escaping @Sendable (any FileOperating) async throws -> Void) {
        guard let undo else { return }
        let files = files
        undo.registerUndo(withTarget: self) { target in
            // task-owner: `pendingUndo`; one undo's file operation, ends when it is done
            target.pendingUndo = Task { try await operation(files) }
        }
    }

    /// Asks for a new name in a sheet (the name without its extension preselected, as Finder does).
    private func askToRename(_ item: FileGridItem, in window: NSWindow?) async {
        // dialog-keys-exempt: CmuxNextScreenshots reaches no CmuxDialogCenter (it depends on CmuxNextFileGrid and CmuxNextFiles only); move to a dialog seam with the Finder pane
        let alert = NSAlert()
        alert.messageText = ScreenshotsStrings.renameTitle
        alert.addButton(withTitle: ScreenshotsStrings.renameConfirm)
        alert.addButton(withTitle: ScreenshotsStrings.cancel)
        let field = NSTextField(string: item.name)
        field.focusRingType = .none
        field.frame = CGRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.layout()
        alert.window.initialFirstResponder = field
        let baseLength = (item.name as NSString).deletingPathExtension.utf16.count
        let response: NSApplication.ModalResponse
        if let window {
            // Begin the sheet here, on the main actor: an `async let` runs it in a
            // child task off main, where AppKit throws (#24760).
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                alert.window.makeFirstResponder(field)
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: baseLength)
            }
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return }
        do {
            try await rename(item, to: field.stringValue, undo: window?.undoManager)
        } catch FileBrowserError.exists {
            showMessage(ScreenshotsStrings.renameExists, in: window)
        } catch FileBrowserError.invalidName {
            showMessage(ScreenshotsStrings.renameInvalid, in: window)
        } catch {
            show(error, in: window)
        }
    }

    private func show(_ error: any Error, in window: NSWindow?) {
        // dialog-keys-exempt: CmuxNextScreenshots reaches no CmuxDialogCenter (it depends on CmuxNextFileGrid and CmuxNextFiles only); move to a dialog seam with the Finder pane
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func showMessage(_ text: String, in window: NSWindow?) {
        // dialog-keys-exempt: CmuxNextScreenshots reaches no CmuxDialogCenter (it depends on CmuxNextFileGrid and CmuxNextFiles only); move to a dialog seam with the Finder pane
        let alert = NSAlert()
        alert.messageText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

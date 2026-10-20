public import AppKit

/// Runs a ``FileGridCommand`` on files: the one path every grid entrypoint
/// (menu, keys, double click) reaches. Quick Look is the grid's own panel
/// and does not come here.
///
/// The disk changes (rename, trash) are not mirrored into any listing: the
/// owner's folder watch sees them, so the grid shows what is on disk, not a
/// guess of it.
@MainActor
public struct FileGridActions {
    private let workspace: any FileGridWorkspace
    private let pasteboard: NSPasteboard
    private let naming: FileGridNaming
    private let writer: FileGridPasteboard

    /// Makes the actions.
    ///
    /// - Parameters:
    ///   - workspace: opens, reveals and trashes (the app's off-main implementation).
    ///   - pasteboard: Copy's pasteboard (default: the general one).
    ///   - naming: the rename rule.
    ///   - writer: what Copy writes (share the grid's, so offered bytes stay readable).
    public init(workspace: any FileGridWorkspace, pasteboard: NSPasteboard = .general,
                naming: FileGridNaming = FileGridNaming(), writer: FileGridPasteboard = FileGridPasteboard()) {
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.naming = naming
        self.writer = writer
    }

    /// Runs `command` on `items`; sheets and errors attach to `window`.
    ///
    /// - Parameters:
    ///   - command: what to do.
    ///   - items: the selected files.
    ///   - window: the grid's window, for the rename sheet and error alerts.
    public func perform(_ command: FileGridCommand, on items: [FileGridItem], in window: NSWindow?) {
        guard command.applies(toSelectionOf: items.count) else { return }
        let urls = items.map(\.url)
        switch command {
        case .open:
            workspace.open(urls)
        case .quickLook:
            break
        case .reveal:
            workspace.reveal(urls)
        case .copy:
            writer.write(items, to: pasteboard)
        case .copyPath:
            writer.writePaths(items, to: pasteboard)
        case .rename:
            guard let item = items.first else { return }
            Task { await rename(item, in: window) }
        case .trash:
            Task {
                do { try await workspace.recycle(urls) } catch { show(error, in: window) }
            }
        }
    }

    /// Asks for a new name in the workspace's dialog and renames the file.
    ///
    /// - Parameters:
    ///   - item: the file.
    ///   - window: the window the dialog blocks; nil for none.
    public func rename(_ item: FileGridItem, in window: NSWindow?) async {
        guard let name = await workspace.askName(title: FileGridStrings.renameTitle, initial: item.name,
                                                 confirm: FileGridStrings.renameConfirm, cancel: FileGridStrings.cancel,
                                                 in: window) else { return }
        do {
            let target = try naming.renamed(item.url, to: name)
            guard target != item.url else { return }
            try FileManager().moveItem(at: item.url, to: target)
        } catch let refusal as FileGridNaming.Refusal {
            showMessage(refusal == .exists ? FileGridStrings.renameExists : FileGridStrings.renameInvalid, in: window)
        } catch {
            show(error, in: window)
        }
    }

    private func show(_ error: any Error, in window: NSWindow?) {
        let error = error as NSError
        workspace.report(error.localizedDescription, detail: error.localizedRecoverySuggestion, in: window)
    }

    private func showMessage(_ text: String, in window: NSWindow?) {
        workspace.report(text, detail: nil, in: window)
    }
}

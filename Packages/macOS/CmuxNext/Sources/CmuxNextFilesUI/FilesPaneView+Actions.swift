import AppKit
import CmuxNextCompat
import CmuxNextFiles

/// The Files commands: one path per command, used by keys, context menus and
/// the content views alike.
extension FilesPaneView {
    func makeActions() -> FilesPaneActions {
        FilesPaneActions(
            activate: { [weak self] entry in self?.activate(entry) },
            select: { [weak self] names, cursor in
                guard let self else { return }
                self.model.adoptSelection(names, cursor: cursor)
            },
            sort: { [weak self] order in self?.model.sortOrder = order },
            rename: { [weak self] entry, name in
                guard let self else { return }
                Task { await self.model.rename(entry.url, to: name) }
            },
            drop: { [weak self] urls, folder, option, command in self?.drop(urls, into: folder, option: option, command: command) },
            menu: { [weak self] entry in self?.contextMenu(for: entry) ?? NSMenu() },
            key: { [weak self] event in self?.handleKey(event) ?? false },
            browse: { [weak self] url in self?.browse(url) }
        )
    }

    func activate(_ entry: FileEntry) {
        Task {
            if case .openFile(let url) = await model.activate(entry) { openFile(url) }
        }
    }

    private func browse(_ url: URL) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists else { return }
        if isDir.boolValue, !DirectoryLister.isPackage(url.lastPathComponent) {
            Task { await model.open(url) }
        } else {
            Task { await model.open(url.deletingLastPathComponent(), select: url) }
        }
    }

    // MARK: Commands

    func openSelection() { for entry in model.selectedEntries { activate(entry) } }

    func toggleQuickLook() {
        quickLook.urls = model.selectedEntries.map(\.url)
        guard !quickLook.urls.isEmpty else { return }
        quickLook.toggle()
    }

    func renameSelection() {
        guard let name = model.selection.count == 1 ? model.selection.first : nil else { return }
        if model.viewMode == .list, let list = currentContent as? FileListView {
            list.beginRename(name)
            return
        }
        Task {
            guard let newName = await prompts.rename(name), newName != name else { return }
            await model.rename(model.folder.appendingPathComponent(name), to: newName)
        }
    }

    func newFolder() { Task { await model.newFolder(named: FilesStrings.untitledFolder) } }
    func duplicate() { Task { await model.duplicateSelection() } }
    func trash() { Task { await model.trashSelection() } }
    func undo() { Task { await model.undo() } }
    func redo() { Task { await model.redo() } }
    func toggleHidden() { model.showHidden.toggle() }
    func copySelection() { FilePasteboard.write(model.selectedEntries.map(\.url), to: .general) }
    func copyPaths() { FilePasteboard.writePaths(model.selectedEntries.map(\.url), to: .general) }

    /// Paste (Cmd+V) copies; Move Item Here (Opt+Cmd+V) moves.
    func paste(move: Bool) {
        let urls = FilePasteboard.fileURLs(.general)
        guard !urls.isEmpty else { return }
        transfer(urls, into: nil, mode: move ? .move : .copy)
    }

    func goToFolder() {
        Task {
            guard let text = await prompts.goToFolder(initial: ""), !text.isEmpty else { return }
            if !(await model.goTo(text)) { NSSound.beep() }
        }
    }

    func revealInFinder() {
        let urls = model.selectedEntries.map(\.url)
        if urls.isEmpty { NSWorkspace.shared.openInBackground(model.folder) } else { NSWorkspace.shared.revealInBackground(urls) }
    }

    private func drop(_ urls: [URL], into folder: URL?, option: Bool, command: Bool) {
        let target = folder ?? model.folder
        transfer(urls, into: folder, mode: DropPolicy().mode(for: urls, into: target, option: option, command: command))
    }

    private func transfer(_ urls: [URL], into folder: URL?, mode: TransferMode) {
        let prompts = self.prompts
        Task {
            await model.transfer(urls, into: folder, mode: mode, resolve: { conflict in
                await prompts.conflict(conflict)
            })
        }
    }

    // MARK: Keys

    /// Finder keys for the focused layout. Arrows and Shift-arrows stay with
    /// the table, grid or browser; these are the rest. Cmd+D, Cmd+1...3 and
    /// Cmd+[ ] keep their cmux meanings (split, workspaces, page history:
    /// the pane plugs Back and Forward into page history).
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        let command = flags.contains(.command), shift = flags.contains(.shift), option = flags.contains(.option)
        let control = flags.contains(.control)
        switch (event.keyCode, command, shift, option, control) {
        case (36, false, false, false, false), (76, false, false, false, false): renameSelectionOrItems(); return true // Return
        case (49, false, false, false, false): toggleQuickLook(); return true // Space
        case (125, true, false, _, false): openSelection(); return true // Cmd+Down
        case (126, true, false, _, false): Task { await model.goUp() }; return true // Cmd+Up
        case (51, true, false, false, false): trash(); return true // Cmd+Delete
        case (51, true, false, true, false): deleteImmediately(); return true // Opt+Cmd+Delete
        case (48, false, let back, false, false): model.selectAlphabetically(forward: !back); return true // Tab, Shift+Tab
        default: break
        }
        if command, shift, !option, !control, let place = GoPlace.place(forShiftCommandKey: chars) {
            go(to: place)
            return true
        }
        if command, control, !shift, !option {
            switch chars.lowercased() {
            case "a": makeAlias(.alias); return true
            case "s": toggleSidebar(); return true
            default: break
            }
        }
        if command, !control {
            switch (chars.lowercased(), shift, option) {
            case ("n", true, false): newFolder(); return true
            case ("g", true, false): goToFolder(); return true
            case (".", true, false), (">", true, false): toggleHidden(); return true
            case ("c", false, true): copyPaths(); return true
            case ("c", false, false): copySelection(); return true
            case ("v", false, let move): paste(move: move); return true
            case ("z", false, false): undo(); return true
            case ("z", true, false): redo(); return true
            case ("a", false, false): model.selectAll(); return true
            case ("o", false, false): openSelection(); return true
            case ("f", false, false): window?.makeFirstResponder(filterFieldForFocus); return true
            case ("r", false, false): revealInFinder(); return true
            case ("i", false, false): getInfo(); return true
            case ("=", _, false), ("+", _, false): setIconSize(CGFloat(zoomSlider.doubleValue) + 16); return true
            case ("-", false, false): setIconSize(CGFloat(zoomSlider.doubleValue) - 16); return true
            default: return false
            }
        }
        if control, command, let digit = Int(chars), (1...3).contains(digit) {
            model.viewMode = [FileViewMode.icons, .list, .columns][digit - 1]
            return true
        }
        if !command, !control, !option, let scalar = chars.unicodeScalars.first, chars.count == 1,
           CharacterSet.alphanumerics.union(.punctuationCharacters).contains(scalar) {
            model.typeSelect(chars)
            return true
        }
        return false
    }

    func handleQuickLookKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: model.moveCursor(by: 1); return true
        case 126: model.moveCursor(by: -1); return true
        case 49: quickLook.toggle(); return true
        default: return false
        }
    }
}

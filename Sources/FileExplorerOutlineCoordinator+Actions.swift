import AppKit
import CmuxFileTree

/// Context menu, Finder-style file actions, inline rename and drops.
extension FileExplorerPanelView.Coordinator: NSTextFieldDelegate {
    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let outlineView else { return }
        let clickedRow = outlineView.clickedRow
        let clicked = clickedRow >= 0 ? outlineView.item(atRow: clickedRow) as? FileExplorerNode : nil
        let targets = clicked.map { contextMenuNodes(clicked: $0) } ?? []
        let isLocal = store.provider is LocalFileExplorerProvider

        if let node = clicked {
            addOpenItems(for: node, isLocal: isLocal, to: menu)
            if isLocal {
                menu.addItem(item(FileExternalOpenText.revealInFinder, #selector(contextMenuRevealInFinder(_:)), node))
            }
            menu.addItem(.separator())
        }

        if store.supportsFileOperations {
            let directory = targetDirectory(for: clicked)
            menu.addItem(item(
                String(localized: "fileExplorer.contextMenu.newFile", defaultValue: "New File"),
                #selector(contextMenuNewFile(_:)), directory as NSString
            ))
            menu.addItem(item(
                String(localized: "fileExplorer.contextMenu.newFolder", defaultValue: "New Folder"),
                #selector(contextMenuNewFolder(_:)), directory as NSString
            ))
            if let node = clicked {
                if targets.count == 1 {
                    menu.addItem(item(
                        String(localized: "fileExplorer.contextMenu.rename", defaultValue: "Rename"),
                        #selector(contextMenuRename(_:)), node
                    ))
                }
                menu.addItem(item(
                    String(localized: "fileExplorer.contextMenu.moveToTrash", defaultValue: "Move to Trash"),
                    #selector(contextMenuMoveToTrash(_:)), node
                ))
            }
            menu.addItem(.separator())
        }

        if let node = clicked {
            menu.addFileExplorerInsertPathItems(
                target: self,
                representedObject: node,
                insertAction: #selector(contextMenuInsertPath(_:)),
                insertRelativeAction: #selector(contextMenuInsertRelativePath(_:))
            )
            menu.addItem(item(
                String(localized: "fileExplorer.contextMenu.copyPath", defaultValue: "Copy Path"),
                #selector(contextMenuCopyPath(_:)), node
            ))
            menu.addItem(item(
                String(localized: "fileExplorer.contextMenu.copyRelativePath", defaultValue: "Copy Relative Path"),
                #selector(contextMenuCopyRelativePath(_:)), node
            ))
            menu.addItem(.separator())
        }

        addViewOptionItems(to: menu)
    }

    /// Show Hidden Files, Sort By and Refresh; shared by the context menu and
    /// the header's view-options button.
    func addViewOptionItems(to menu: NSMenu) {
        let hidden = item(
            String(localized: "fileExplorer.contextMenu.showHiddenFiles", defaultValue: "Show Hidden Files"),
            #selector(toggleHiddenFiles(_:)), nil
        )
        hidden.state = store.showHiddenFiles ? .on : .off
        menu.addItem(hidden)

        let sortMenu = NSMenu(title: String(localized: "fileExplorer.contextMenu.sortBy", defaultValue: "Sort By"))
        let keys: [(FileTreeSortOrder.Key, String)] = [
            (.name, String(localized: "fileExplorer.sort.name", defaultValue: "Name")),
            (.kind, String(localized: "fileExplorer.sort.kind", defaultValue: "Kind")),
            (.dateModified, String(localized: "fileExplorer.sort.dateModified", defaultValue: "Date Modified")),
            (.size, String(localized: "fileExplorer.sort.size", defaultValue: "Size")),
        ]
        for (key, title) in keys {
            let sortItem = item(title, #selector(selectSortKey(_:)), key.rawValue as NSString)
            sortItem.state = store.sortOrder.key == key ? .on : .off
            sortMenu.addItem(sortItem)
        }
        sortMenu.addItem(.separator())
        let ascending = item(
            String(localized: "fileExplorer.sort.ascending", defaultValue: "Ascending"),
            #selector(selectSortDirection(_:)), NSNumber(value: true)
        )
        ascending.state = store.sortOrder.ascending ? .on : .off
        sortMenu.addItem(ascending)
        let descending = item(
            String(localized: "fileExplorer.sort.descending", defaultValue: "Descending"),
            #selector(selectSortDirection(_:)), NSNumber(value: false)
        )
        descending.state = store.sortOrder.ascending ? .off : .on
        sortMenu.addItem(descending)
        sortMenu.addItem(.separator())
        let foldersFirst = item(
            String(localized: "fileExplorer.sort.foldersFirst", defaultValue: "Keep Folders on Top"),
            #selector(toggleFoldersFirst(_:)), nil
        )
        foldersFirst.state = store.sortOrder.foldersFirst ? .on : .off
        sortMenu.addItem(foldersFirst)
        let sortItem = NSMenuItem(title: sortMenu.title, action: nil, keyEquivalent: "")
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)

        menu.addItem(item(
            String(localized: "fileExplorer.contextMenu.refresh", defaultValue: "Refresh"),
            #selector(refreshTree(_:)), nil
        ))
    }

    private func addOpenItems(for node: FileExplorerNode, isLocal: Bool, to menu: NSMenu) {
        if node.isDirectory {
            menu.addItem(item(String(localized: "fileExplorer.contextMenu.open", defaultValue: "Open"),
                              #selector(contextMenuOpen(_:)), node))
            return
        }
        menu.addItem(item(
            String(localized: "fileExplorer.contextMenu.openInCmux", defaultValue: "Open in cmux"),
            #selector(contextMenuOpenInCmux(_:)), node
        ))
        if isLocal {
            FileExplorerExternalOpenMenuItems(
                fileURL: URL(fileURLWithPath: node.path),
                target: self,
                action: #selector(contextMenuOpenExternally(_:))
            ).add(to: menu)
            menu.addItem(item(
                String(localized: "fileExplorer.contextMenu.quickLook", defaultValue: "Quick Look"),
                #selector(contextMenuQuickLook(_:)), node
            ))
        }
    }

    private func item(_ title: String, _ action: Selector, _ represented: Any?) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = represented
        return menuItem
    }

    func contextMenuNodes(clicked node: FileExplorerNode) -> [FileExplorerNode] {
        guard let outlineView else { return [node] }
        let clickedRow = outlineView.clickedRow
        let selectedRows = outlineView.selectedRowIndexes
        guard clickedRow >= 0, selectedRows.contains(clickedRow) else {
            return [node]
        }
        let nodes = selectedRows.compactMap { row -> FileExplorerNode? in
            guard row >= 0, row < outlineView.numberOfRows else { return nil }
            return outlineView.item(atRow: row) as? FileExplorerNode
        }
        return nodes.isEmpty ? [node] : nodes
    }

    /// New items go into a clicked folder, a clicked file's folder, or the root.
    func targetDirectory(for node: FileExplorerNode?) -> String {
        guard let node else { return store.rootPath }
        if node.isDirectory { return node.path }
        return node.parent?.path ?? store.rootPath
    }

    func contextMenuDidOpen() {
        store.freezeTreeUpdates()
    }

    /// Updates wait for the menu highlight to finish tearing down (#12914).
    func contextMenuDidClose() {
        Task { @MainActor [weak self] in
            self?.store.thawTreeUpdates()
        }
    }

    // MARK: - Menu actions

    @objc func contextMenuOpen(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode, let outlineView else { return }
        let row = outlineView.row(forItem: node)
        if row >= 0 { openNode(in: outlineView, at: row) }
    }

    @objc func contextMenuOpenInCmux(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        onOpenFilePreview(node.path)
    }

    @objc func contextMenuOpenExternally(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? FileExplorerExternalOpenRequest else { return }
        FileExternalOpenAction.open(fileURL: request.fileURL, applicationURL: request.applicationURL)
    }

    @objc func contextMenuRevealInFinder(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        let urls = contextMenuNodes(clicked: node).map { URL(fileURLWithPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func contextMenuQuickLook(_ sender: NSMenuItem) {
        (outlineView as? FileExplorerNSOutlineView)?.toggleQuickLook()
    }

    @objc func contextMenuCopyPath(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        let paths = contextMenuNodes(clicked: node).map(\.path)
        GhosttyApp.terminalPasteboard.writeString(paths.joined(separator: "\n"), to: .general)
    }

    @objc func contextMenuCopyRelativePath(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        let paths = contextMenuNodes(clicked: node).map {
            FileExplorerTerminalPathInsertion.relativePath(for: $0.path, rootPath: store.rootPath)
        }
        GhosttyApp.terminalPasteboard.writeString(paths.joined(separator: "\n"), to: .general)
    }

    @objc func contextMenuNewFile(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? String else { return }
        createItem(in: directory, isFolder: false)
    }

    @objc func contextMenuNewFolder(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? String else { return }
        createItem(in: directory, isFolder: true)
    }

    @objc func contextMenuRename(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        beginRenaming(node)
    }

    @objc func contextMenuMoveToTrash(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        moveToTrash(contextMenuNodes(clicked: node))
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        state.showHiddenFiles.toggle()
        store.showHiddenFiles = state.showHiddenFiles
    }

    @objc func selectSortKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = FileTreeSortOrder.Key(rawValue: raw) else { return }
        var order = store.sortOrder
        order.key = key
        applySortOrder(order)
    }

    @objc func selectSortDirection(_ sender: NSMenuItem) {
        guard let ascending = (sender.representedObject as? NSNumber)?.boolValue else { return }
        var order = store.sortOrder
        order.ascending = ascending
        applySortOrder(order)
    }

    @objc func toggleFoldersFirst(_ sender: NSMenuItem) {
        var order = store.sortOrder
        order.foldersFirst.toggle()
        applySortOrder(order)
    }

    private func applySortOrder(_ order: FileTreeSortOrder) {
        state.sortOrder = order
        store.sortOrder = order
    }

    @objc func refreshTree(_ sender: Any?) {
        store.refreshVisibleDirectories()
        store.refreshGitStatus()
    }

    // MARK: - File operations

    func createItem(in directory: String, isFolder: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.store.createItem(inDirectory: directory, isFolder: isFolder)
            } catch {
                self.present(error)
            }
        }
    }

    func moveToTrash(_ nodes: [FileExplorerNode]) {
        guard store.supportsFileOperations, !nodes.isEmpty else { return }
        // Trashing a folder and something inside it would fail for the child.
        let paths = nodes.map(\.path).filter { path in
            !nodes.contains { $0.path != path && FileExplorerStore.path(path, isContainedIn: $0.path) }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.store.moveToTrash(paths: paths)
            } catch {
                self.present(error)
            }
        }
    }

    func present(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "fileExplorer.operation.failedTitle", defaultValue: "The operation couldn’t be completed")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "fileExplorer.preview.ok", defaultValue: "OK"))
        _ = alert.runCmuxModal(presentingWindow: outlineView?.window)
    }

    // MARK: - Inline rename

    func beginRenaming(_ node: FileExplorerNode) {
        guard store.supportsFileOperations, let outlineView else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        cancelRenaming()
        outlineView.scrollRowToVisible(row)
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileExplorerCellView else { return }
        renamingCell = cell
        renamingPath = node.path
        if !cell.beginRenaming(delegate: self) {
            renamingCell = nil
            renamingPath = nil
        }
    }

    func cancelRenaming() {
        guard let cell = renamingCell else {
            renamingPath = nil
            return
        }
        renamingCell = nil
        renamingPath = nil
        cell.endRenaming()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === renamingCell?.textField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelRenaming()
            outlineView.map { _ = $0.window?.makeFirstResponder($0) }
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === renamingCell?.textField,
              let path = renamingPath else { return }
        let newName = field.stringValue
        let cell = renamingCell
        renamingCell = nil
        renamingPath = nil
        cell?.endRenaming()
        if let outlineView { _ = outlineView.window?.makeFirstResponder(outlineView) }
        guard newName != (path as NSString).lastPathComponent else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.store.renameItem(atPath: path, to: newName)
            } catch {
                self.present(error)
            }
        }
    }

    // MARK: - Pasteboard (Edit > Copy / Paste)

    func copySelection(in outlineView: NSOutlineView) -> Bool {
        let nodes = selectedNodes(in: outlineView)
        guard !nodes.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if store.provider is LocalFileExplorerProvider {
            pasteboard.writeObjects(nodes.map { URL(fileURLWithPath: $0.path) as NSURL })
        }
        pasteboard.setString(nodes.map(\.path).joined(separator: "\n"), forType: .string)
        return true
    }

    func pasteFiles(in outlineView: NSOutlineView) -> Bool {
        guard store.supportsFileOperations,
              let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        let anchor = store.selectedPath.flatMap { store.nodesByPath[$0] }
        let directory = targetDirectory(for: anchor)
        importItems(urls, into: directory, move: false)
        return true
    }

    func importItems(_ urls: [URL], into directory: String, move: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.store.importItems(urls, into: directory, move: move)
                self.fileExplorerTreeDidChangeSelection(self.store, scrollToAnchor: true)
            } catch {
                self.present(error)
            }
        }
    }

    // MARK: - Drop (drag in)

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard store.supportsFileOperations,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return [] }
        var target = item as? FileExplorerNode
        if let node = target, !node.isDirectory {
            target = node.parent
        }
        // Always drop onto a folder row (or the root), never between rows.
        outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        let directory = target?.path ?? store.rootPath
        if urls.contains(where: { FileExplorerStore.path(directory, isContainedIn: $0.path) }) { return [] }
        return dropOperation(for: info, urls: urls, directory: directory)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard store.supportsFileOperations,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        let directory = (item as? FileExplorerNode).map { $0.isDirectory ? $0.path : targetDirectory(for: $0) }
            ?? store.rootPath
        let operation = dropOperation(for: info, urls: urls, directory: directory)
        guard !operation.isEmpty else { return false }
        importItems(urls, into: directory, move: operation == .move)
        return true
    }

    /// Finder semantics: Option copies, otherwise same-volume drops move and
    /// cross-volume drops copy.
    private func dropOperation(for info: any NSDraggingInfo, urls: [URL], directory: String) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        if NSEvent.modifierFlags.contains(.option), mask.contains(.copy) { return .copy }
        let destinationVolume = Self.volumeIdentifier(for: URL(fileURLWithPath: directory))
        let sameVolume = destinationVolume != nil && urls.allSatisfy { Self.volumeIdentifier(for: $0) == destinationVolume }
        if sameVolume, mask.contains(.move) || mask.contains(.generic) { return .move }
        if mask.contains(.copy) { return .copy }
        return mask.contains(.generic) ? .copy : []
    }

    private static func volumeIdentifier(for url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }
}

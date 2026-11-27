import AppKit
import CmuxNextDesign
import CmuxNextFiles

/// The Files context menus, in Finder's order. Every item calls the same
/// command its key does (``FilesPaneView/handleKey(_:)``).
extension FilesPaneView {
    func contextMenu(for entry: FileEntry?) -> NSMenu {
        let menu = NSMenu()
        if entry != nil {
            menu.addItem(item(FilesStrings.open, "doc", #selector(menuOpen)))
            // Open as Text: a page cmux renders (HTML, SVG, Markdown) as its source in the code editor.
            if let entry, let fileMenu {
                let url = entry.url
                let folder = entry.kind == .folder || entry.kind == .package
                if let text = fileMenu.openAsTextItem(forFileNamed: entry.name, isDirectory: folder, resolve: { url }) { menu.addItem(text) }
            }
            // Open With ▸ (every app the system reports, the default first, Other…), Finder's
            // second row; the clicked item's type picks the apps.
            if let entry, let fileMenu {
                let url = entry.url
                menu.addItem(fileMenu.openWithItem(forFileNamed: entry.name, isDirectory: entry.kind == .folder || entry.kind == .package) { url })
            }
            if entry?.kind == .package {
                menu.addItem(item(FilesStrings.showPackageContents, "shippingbox", #selector(menuShowPackage)))
            }
            menu.addItem(item(FilesStrings.quickLook, "eye", #selector(menuQuickLook)))
            menu.addItem(item(FilesStrings.getInfo, "info.circle", #selector(menuGetInfo)))
            menu.addItem(.separator())
            menu.addItem(item(model.selection.count > 1 ? FilesStrings.renameItems : FilesStrings.rename, "pencil", #selector(menuRename)))
            menu.addItem(item(FilesStrings.duplicate, "plus.square.on.square", #selector(menuDuplicate)))
            menu.addItem(item(FilesStrings.makeAlias, "arrowshape.turn.up.right", #selector(menuMakeAlias)))
            menu.addItem(item(FilesStrings.makeSymlink, "link.badge.plus", #selector(menuMakeSymlink)))
            menu.addItem(item(FilesStrings.compress, "doc.zipper", #selector(menuCompress)))
            if model.selectedEntries.contains(where: { $0.name.lowercased().hasSuffix(".zip") }) {
                menu.addItem(item(FilesStrings.expand, "arrow.up.bin", #selector(menuExpand)))
            }
            menu.addItem(item(FilesStrings.moveToTrash, "trash", #selector(menuTrash)))
            menu.addItem(item(FilesStrings.deleteImmediately, "xmark.bin", #selector(menuDeleteNow)))
            menu.addItem(.separator())
            menu.addItem(item(FilesStrings.copy, "doc.on.doc", #selector(menuCopy)))
            menu.addItem(item(FilesStrings.copyPath, "link", #selector(menuCopyPath)))
            if let entry, let fileMenu {
                let url = entry.url
                menu.addItem(fileMenu.shareItem { url })
            }
        }
        menu.addItem(item(FilesStrings.paste, "doc.on.clipboard", #selector(menuPaste)))
        menu.addItem(item(FilesStrings.moveHere, "arrow.down.doc", #selector(menuMoveHere)))
        menu.addItem(.separator())
        menu.addItem(item(FilesStrings.newFolder, "folder.badge.plus", #selector(menuNewFolder)))
        menu.addItem(item(FilesStrings.goToFolder, "arrow.right.circle", #selector(menuGoTo)))
        menu.addItem(item(model.showHidden ? FilesStrings.hideHidden : FilesStrings.showHidden, model.showHidden ? "eye.slash" : "eye", #selector(menuHidden)))
        menu.addItem(.separator())
        let undoItem = item(FilesStrings.undo, "arrow.uturn.backward", #selector(menuUndo))
        undoItem.isEnabled = model.canUndo
        menu.addItem(undoItem)
        let redoItem = item(FilesStrings.redo, "arrow.uturn.forward", #selector(menuRedo))
        redoItem.isEnabled = model.canRedo
        menu.addItem(redoItem)
        menu.addItem(.separator())
        menu.addItem(item(FilesStrings.showInFinder, "macwindow", #selector(menuReveal)))
        menu.autoenablesItems = false
        return menu
    }

    private func item(_ title: String, _ symbol: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage.menuSymbol(symbol)
        return item
    }

    @objc private func menuOpen() { openSelection() }
    @objc private func menuQuickLook() { toggleQuickLook() }
    @objc private func menuRename() { renameSelectionOrItems() }
    @objc private func menuShowPackage() { showPackageContents() }
    @objc private func menuGetInfo() { getInfo() }
    @objc private func menuMakeAlias() { makeAlias(.alias) }
    @objc private func menuMakeSymlink() { makeAlias(.symlink) }
    @objc private func menuCompress() { compress() }
    @objc private func menuExpand() { expandSelection() }
    @objc private func menuDeleteNow() { deleteImmediately() }
    @objc private func menuDuplicate() { duplicate() }
    @objc private func menuTrash() { trash() }
    @objc private func menuCopy() { copySelection() }
    @objc private func menuCopyPath() { copyPaths() }
    @objc private func menuPaste() { paste(move: false) }
    @objc private func menuMoveHere() { paste(move: true) }
    @objc private func menuNewFolder() { newFolder() }
    @objc private func menuGoTo() { goToFolder() }
    @objc private func menuHidden() { toggleHidden() }
    @objc private func menuUndo() { undo() }
    @objc private func menuRedo() { redo() }
    @objc private func menuReveal() { revealInFinder() }
}

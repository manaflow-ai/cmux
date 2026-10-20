import AppKit
import CmuxNextFiles

/// The Files context menus, in Finder's order. Every item calls the same
/// command its key does (``FilesPaneView/handleKey(_:)``).
extension FilesPaneView {
    func contextMenu(for entry: FileEntry?) -> NSMenu {
        let menu = NSMenu()
        if entry != nil {
            menu.addItem(item(FilesStrings.open, "doc", #selector(menuOpen)))
            menu.addItem(item(FilesStrings.quickLook, "eye", #selector(menuQuickLook)))
            menu.addItem(.separator())
            menu.addItem(item(FilesStrings.rename, "pencil", #selector(menuRename)))
            menu.addItem(item(FilesStrings.duplicate, "plus.square.on.square", #selector(menuDuplicate)))
            menu.addItem(item(FilesStrings.moveToTrash, "trash", #selector(menuTrash)))
            menu.addItem(.separator())
            menu.addItem(item(FilesStrings.copy, "doc.on.doc", #selector(menuCopy)))
            menu.addItem(item(FilesStrings.copyPath, "link", #selector(menuCopyPath)))
        }
        menu.addItem(item(FilesStrings.paste, "doc.on.clipboard", #selector(menuPaste)))
        menu.addItem(item(FilesStrings.moveHere, "arrow.down.doc", #selector(menuMoveHere)))
        menu.addItem(.separator())
        menu.addItem(item(FilesStrings.newFolder, "folder.badge.plus", #selector(menuNewFolder)))
        menu.addItem(item(FilesStrings.goToFolder, "arrow.right.circle", #selector(menuGoTo)))
        menu.addItem(item(model.showHidden ? FilesStrings.hideHidden : FilesStrings.showHidden, "eye.slash", #selector(menuHidden)))
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
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func menuOpen() { openSelection() }
    @objc private func menuQuickLook() { toggleQuickLook() }
    @objc private func menuRename() { renameSelection() }
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

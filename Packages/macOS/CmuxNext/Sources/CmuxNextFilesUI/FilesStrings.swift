import Foundation

/// The Files pane's text (table `Files`, 21 languages).
nonisolated enum FilesStrings {
    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "Files", bundle: .module)
    }

    static var title: String { t("files.title", "Files") }
    static var back: String { t("files.back", "Back") }
    static var forward: String { t("files.forward", "Forward") }
    static var enclosingFolder: String { t("files.enclosingFolder", "Enclosing Folder") }
    static var viewIcons: String { t("files.view.icons", "as Icons") }
    static var viewList: String { t("files.view.list", "as List") }
    static var viewColumns: String { t("files.view.columns", "as Columns") }
    static var filter: String { t("files.filter", "Filter") }
    static var columnName: String { t("files.column.name", "Name") }
    static var columnModified: String { t("files.column.modified", "Date Modified") }
    static var columnSize: String { t("files.column.size", "Size") }
    static var columnKind: String { t("files.column.kind", "Kind") }
    static var loading: String { t("files.loading", "Loading…") }
    static var open: String { t("files.menu.open", "Open") }
    static var quickLook: String { t("files.menu.quickLook", "Quick Look") }
    static var rename: String { t("files.menu.rename", "Rename") }
    static var duplicate: String { t("files.menu.duplicate", "Duplicate") }
    static var moveToTrash: String { t("files.menu.moveToTrash", "Move to Trash") }
    static var copy: String { t("files.menu.copy", "Copy") }
    static var copyPath: String { t("files.menu.copyPath", "Copy as Pathname") }
    static var paste: String { t("files.menu.paste", "Paste") }
    static var moveHere: String { t("files.menu.moveHere", "Move Item Here") }
    static var newFolder: String { t("files.menu.newFolder", "New Folder") }
    static var showInFinder: String { t("files.menu.showInFinder", "Show in Finder") }
    static var showHidden: String { t("files.menu.showHidden", "Show Hidden Files") }
    static var hideHidden: String { t("files.menu.hideHidden", "Hide Hidden Files") }
    static var goToFolder: String { t("files.menu.goToFolder", "Go to Folder…") }
    static var undo: String { t("files.menu.undo", "Undo") }
    static var redo: String { t("files.menu.redo", "Redo") }
    static var go: String { t("files.goTo.go", "Go") }
    static var cancel: String { t("files.goTo.cancel", "Cancel") }
    static var goToTitle: String { t("files.goTo.title", "Go to Folder") }
    static var noSuchFolder: String { t("files.goTo.missing", "There is no folder or file at this path.") }
    static var keepBoth: String { t("files.conflict.keepBoth", "Keep Both") }
    static var stop: String { t("files.conflict.stop", "Stop") }
    static var replace: String { t("files.conflict.replace", "Replace") }
    static var skip: String { t("files.conflict.skip", "Skip") }
    static var applyToAll: String { t("files.conflict.applyToAll", "Apply to All") }
    static var untitledFolder: String { t("files.untitledFolder", "untitled folder") }
    static var copyWord: String { t("files.copyWord", "copy") }
    static var cannotOpen: String { t("files.cannotOpen", "This folder can’t be opened.") }
    static var empty: String { t("files.empty", "This folder is empty.") }

    static func conflict(_ name: String) -> String {
        String(format: t("files.conflict.message", "An item named “%@” already exists in this location."), name)
    }

    static func items(_ count: Int) -> String {
        String(format: t("files.status.items", "%lld items"), count)
    }

    static func selected(_ selected: Int, of total: Int) -> String {
        String(format: t("files.status.selected", "%1$lld of %2$lld selected"), selected, total)
    }

    static func copying(_ count: Int) -> String {
        String(format: t("files.status.copying", "Copying %lld items…"), count)
    }
}

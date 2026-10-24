import CmuxNextCompat
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

    static var favorites: String { t("files.sidebar.favorites", "Favorites") }
    static var locations: String { t("files.sidebar.locations", "Locations") }
    static var eject: String { t("files.sidebar.eject", "Eject") }
    static var removeFromSidebar: String { t("files.sidebar.remove", "Remove from Sidebar") }
    static var getInfo: String { t("files.menu.getInfo", "Get Info") }
    static var renameItems: String { t("files.menu.renameItems", "Rename Items…") }
    static var makeAlias: String { t("files.menu.makeAlias", "Make Alias") }
    static var makeSymlink: String { t("files.menu.makeSymlink", "Make Symbolic Link") }
    static var compress: String { t("files.menu.compress", "Compress") }
    static var expand: String { t("files.menu.expand", "Expand") }
    static var showPackageContents: String { t("files.menu.showPackage", "Show Package Contents") }
    static var deleteImmediately: String { t("files.menu.deleteNow", "Delete Immediately…") }
    static var delete: String { t("files.delete.button", "Delete") }
    static var deleteCannotUndo: String { t("files.delete.cannotUndo", "You can’t undo this action.") }
    static var archiveName: String { t("files.archiveName", "Archive") }
    static var aliasWord: String { t("files.aliasWord", "alias") }
    static var infoKind: String { t("files.info.kind", "Kind:") }
    static var infoSize: String { t("files.info.size", "Size:") }
    static var infoWhere: String { t("files.info.where", "Where:") }
    static var infoCreated: String { t("files.info.created", "Created:") }
    static var infoModified: String { t("files.info.modified", "Modified:") }
    static var infoOpened: String { t("files.info.opened", "Last opened:") }
    static var infoOwner: String { t("files.info.owner", "Owner:") }
    static var infoPermissions: String { t("files.info.permissions", "Permissions:") }
    static var infoLocked: String { t("files.info.locked", "Locked") }
    static var infoHideExtension: String { t("files.info.hideExtension", "Hide extension") }
    static var infoCalculating: String { t("files.info.calculating", "Calculating…") }
    static var renameReplace: String { t("files.rename.replace", "Replace Text") }
    static var renameAdd: String { t("files.rename.add", "Add Text") }
    static var renameFormat: String { t("files.rename.format", "Format") }
    static var renameNameIndex: String { t("files.rename.nameIndex", "Name and Index") }
    static var renameNameCounter: String { t("files.rename.nameCounter", "Name and Counter") }
    static var renameNameDate: String { t("files.rename.nameDate", "Name and Date") }
    static var renameAfter: String { t("files.rename.after", "after name") }
    static var renameBefore: String { t("files.rename.before", "before name") }
    static var renameFind: String { t("files.rename.find", "Find:") }
    static var renameReplaceWith: String { t("files.rename.replaceWith", "Replace with:") }
    static var renameText: String { t("files.rename.text", "Text:") }
    static var renameCustomFormat: String { t("files.rename.customFormat", "Custom Format:") }
    static var renameStartAt: String { t("files.rename.startAt", "Start numbers at:") }
    static var renameCaseSensitive: String { t("files.rename.caseSensitive", "Match case") }

    static var iconSize: String { t("files.iconSize", "Icon size") }

    static func available(_ size: String) -> String {
        String(format: t("files.status.available", "%@ available"), size)
    }

    static func infoTitle(_ name: String) -> String {
        String(format: t("files.info.title", "%@ Info"), name)
    }

    static func infoBytes(_ size: String, _ bytes: Int64,
                          preferredLocalizations: [String] = Bundle.module.preferredLocalizations, locale: Locale = .current) -> String {
        Bundle.module.localizedString(forKey: "files.info.bytes", value: "%1$@ (%2$lld bytes)", table: "Files",
                                      arguments: [.text(size), .count(Int(clamping: bytes))],
                                      preferredLocalizations: preferredLocalizations, locale: locale)
    }

    static func infoFolderSize(_ size: String, _ items: Int,
                               preferredLocalizations: [String] = Bundle.module.preferredLocalizations, locale: Locale = .current) -> String {
        Bundle.module.localizedString(forKey: "files.info.folderSize", value: "%1$@ for %2$lld items", table: "Files",
                                      arguments: [.text(size), .count(items)],
                                      preferredLocalizations: preferredLocalizations, locale: locale)
    }

    static func renameExample(_ name: String) -> String {
        String(format: t("files.rename.example", "Example: %@"), name)
    }

    static func renameItemsTitle(_ count: Int,
                                 preferredLocalizations: [String] = Bundle.module.preferredLocalizations, locale: Locale = .current) -> String {
        Bundle.module.localizedString(forKey: "files.rename.title", value: "Rename %lld Items", table: "Files",
                                      arguments: [.count(count)], preferredLocalizations: preferredLocalizations, locale: locale)
    }

    static func deleteConfirm(_ count: Int,
                              preferredLocalizations: [String] = Bundle.module.preferredLocalizations, locale: Locale = .current) -> String {
        Bundle.module.localizedString(forKey: "files.delete.confirm",
                                      value: "Are you sure you want to delete these %lld items immediately?",
                                      table: "Files",
                                      arguments: [.count(count)], preferredLocalizations: preferredLocalizations, locale: locale)
    }

    static func conflict(_ name: String) -> String {
        String(format: t("files.conflict.message", "An item named “%@” already exists in this location."), name)
    }

    static func items(_ count: Int,
                      preferredLocalizations: [String] = Bundle.module.preferredLocalizations, locale: Locale = .current) -> String {
        Bundle.module.localizedString(forKey: "files.status.items", value: "%lld items", table: "Files",
                                      arguments: [.count(count)], preferredLocalizations: preferredLocalizations, locale: locale)
    }

    static func selected(_ selected: Int, of total: Int) -> String {
        String(format: t("files.status.selected", "%1$lld of %2$lld selected"), selected, total)
    }

    static func copying(_ count: Int,
                        preferredLocalizations: [String] = Bundle.module.preferredLocalizations, locale: Locale = .current) -> String {
        Bundle.module.localizedString(forKey: "files.status.copying", value: "Copying %lld items…", table: "Files",
                                      arguments: [.count(count)], preferredLocalizations: preferredLocalizations, locale: locale)
    }
}

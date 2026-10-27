import AppKit
import CmuxNextFiles

/// What a Files content view (list, icons, columns) asks its pane to do.
///
/// Content views hold entry snapshots and this bundle of closures, never the
/// model (the snapshot boundary for list subtrees): a model change that does
/// not touch their rows never re-renders them.
struct FilesPaneActions {
    /// Open an item (double-click, Return-free Cmd+Down).
    var activate: (FileEntry) -> Void
    /// The view's selection changed to these names; `cursor` is the clicked or moved-to one.
    var select: (_ names: Set<String>, _ cursor: String?) -> Void
    /// A column header asked for this order.
    var sort: (FileSortOrder) -> Void
    /// An inline rename finished with this name.
    var rename: (FileEntry, String) -> Void
    /// Files were dropped into `folder` (nil: the folder shown) with Option/Command held as given.
    var drop: (_ urls: [URL], _ folder: URL?, _ option: Bool, _ command: Bool) -> Void
    /// The context menu for the clicked item (nil: the folder background).
    var menu: (FileEntry?) -> NSMenu
    /// A key the view did not use (type-select, shortcuts).
    var key: (NSEvent) -> Bool
    /// The column view showed this folder as the deepest column.
    var browse: (URL) -> Void
}

/// One way of laying out a folder in a Files pane.
@MainActor
protocol FileContentView: AnyObject {
    /// The view to embed.
    var view: NSView { get }
    /// Shows these entries (in order) of `folder` with these names selected.
    func show(_ entries: [FileEntry], of folder: URL, selection: Set<String>)
    /// Starts inline rename of the item named `name`.
    func beginRename(_ name: String)
    /// Scrolls the item named `name` into view.
    func reveal(_ name: String)
    /// The view that takes keyboard focus.
    var focusView: NSView { get }
    /// Redraws the icons of the items on screen (an icon that showed a placeholder landed).
    func redrawIcons()
}

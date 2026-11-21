public import AppKit

/// A folder as an `NSMenu` (bar folders, the overflow chevron, Other
/// Bookmarks). Submenus fill when they open, so a large tree costs nothing
/// until the user walks into it.
@MainActor
public final class BookmarkFolderMenu: NSObject, NSMenuDelegate {
    private weak var source: (any BookmarksBarSource)?
    private let folder: String
    /// Nodes listed before the folder's own children (the overflow menu's hidden bar items).
    private let leading: [BookmarkNode]
    private var children: [BookmarkFolderMenu] = []
    public let menu: NSMenu

    public init(source: any BookmarksBarSource, folder: String, title: String, leading: [BookmarkNode] = [], includeChildren: Bool = true) {
        self.source = source
        self.folder = includeChildren ? folder : ""
        self.leading = leading
        menu = NSMenu(title: title)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        children.removeAll()
        guard let source else { return }
        var nodes = leading
        if !folder.isEmpty { nodes += source.bookmarkChildren(of: folder) }
        for node in nodes { menu.addItem(item(for: node, source: source)) }
        let urls = folder.isEmpty ? [] : source.bookmarkChildren(of: folder).filter { !$0.isFolder }
        if nodes.isEmpty {
            let empty = NSMenuItem(title: BookmarkStrings.emptyFolder, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else if urls.count > 1 {
            menu.addItem(.separator())
            let all = NSMenuItem(title: BookmarkStrings.openAll(urls.count), action: #selector(openAll(_:)), keyEquivalent: "")
            all.target = self
            menu.addItem(all)
        }
    }

    private func item(for node: BookmarkNode, source: any BookmarksBarSource) -> NSMenuItem {
        let item = NSMenuItem(title: Self.menuTitle(node.displayTitle), action: nil, keyEquivalent: "")
        item.image = source.favicon(for: node)
        item.representedObject = node.id
        item.toolTip = node.url.map { "\(node.displayTitle)\n\($0.absoluteString)" }
        if node.isFolder {
            let child = BookmarkFolderMenu(source: source, folder: node.id, title: node.displayTitle)
            children.append(child)
            item.submenu = child.menu
        } else {
            item.target = self
            item.action = #selector(open(_:))
        }
        return item
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let source, let id = sender.representedObject as? String,
              let node = (leading + source.bookmarkChildren(of: folder)).first(where: { $0.id == id }) else { return }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        source.open(node, disposition: .from(flags))
    }

    @objc private func openAll(_ sender: NSMenuItem) {
        source?.openAll(in: folder)
    }

    /// Long titles are cut in the middle of a menu, not at the screen edge.
    static func menuTitle(_ title: String) -> String {
        guard title.count > 60 else { return title }
        return String(title.prefix(57)) + "…"
    }
}

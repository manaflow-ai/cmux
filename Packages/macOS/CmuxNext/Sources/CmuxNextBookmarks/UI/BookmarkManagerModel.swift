public import Foundation
public import Observation

/// What the `cmux://bookmarks` page needs from the App: one browser
/// profile's tree and the verbs on it.
@MainActor
public protocol BookmarkManagerSource: AnyObject {
    /// The tree shown now (the page's browser profile).
    var managerTree: BookmarkTree { get }
    /// Applies an edit; false (with the reason shown by the host) on refusal.
    @discardableResult func apply(_ operation: BookmarkOperation) -> Bool
    func open(_ node: BookmarkNode, disposition: BookmarkOpenDisposition)
    func openAll(in folder: String)
    /// Asks for an HTML file and imports it (host panel).
    func importHTML()
    /// Lists the browsers on this Mac and imports the profiles the person picks.
    func importFromBrowser()
    /// Asks where to save and writes the HTML export (host panel).
    func exportHTML()
    func copy(_ text: String)
}

/// The page's state: selected folder, search text, selection, editor.
@Observable
public final class BookmarkManagerModel {
    public private(set) var tree = BookmarkTree()
    /// The folder whose children the list shows (a root or a folder id).
    public var folder: String = BookmarkRoot.bar.rawValue
    public var query = ""
    public var selection: Set<String> = []
    public var editor: BookmarkEditorState?
    public var errorMessage: String?
    var colors = BookmarkPageColors()
    @ObservationIgnored public weak var source: (any BookmarkManagerSource)?

    public init(source: (any BookmarkManagerSource)?) {
        self.source = source
        reload()
    }

    /// Pulls the tree again (the host calls it when the bookmarks change).
    public func reload() {
        guard let source else { return }
        tree = source.managerTree
        if !tree.isContainer(folder) { folder = BookmarkRoot.bar.rawValue }
        selection = selection.filter { tree.node($0) != nil }
    }

    /// Rows of the list: the folder's children, or search results.
    public var rows: [BookmarkNode] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? tree.children(of: folder) : BookmarkSearch.results(tree, text: query)
    }

    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    public var folderChoices: [BookmarkFolderChoice] {
        BookmarkFolderChoice.all(in: tree, barTitle: BookmarkStrings.barTitle, otherTitle: BookmarkStrings.otherBookmarks)
    }

    public func title(ofFolder id: String) -> String {
        switch BookmarkRoot(rawValue: id) {
        case .bar: BookmarkStrings.barTitle
        case .other: BookmarkStrings.otherBookmarks
        case nil: tree.node(id)?.displayTitle ?? ""
        }
    }

    // MARK: Verbs

    public func activate(_ node: BookmarkNode) {
        if node.isFolder {
            folder = node.id
            query = ""
            selection = []
        } else {
            source?.open(node, disposition: .currentTab)
        }
    }

    public func startAddBookmark() {
        editor = BookmarkEditorState(mode: .addBookmark, title: "", url: "", folder: isSearching ? BookmarkRoot.bar.rawValue : folder,
                                     isFolder: false)
    }

    public func startAddFolder() {
        editor = BookmarkEditorState(mode: .addFolder, title: BookmarkStrings.newFolder, url: "",
                                     folder: isSearching ? BookmarkRoot.bar.rawValue : folder, isFolder: true)
    }

    public func startEdit(_ node: BookmarkNode) {
        editor = BookmarkEditorState(mode: .edit(node.id), title: node.title, url: node.url?.absoluteString ?? "", folder: node.parent,
                                     isFolder: node.isFolder)
    }

    /// Saves the editor; false keeps it open (bad URL).
    @discardableResult
    public func commitEditor(_ state: BookmarkEditorState) -> Bool {
        let url = state.isFolder ? nil : BookmarkURL.parse(state.url)
        if !state.isFolder, url == nil {
            errorMessage = BookmarkStrings.invalidURL
            return false
        }
        var operations: [BookmarkOperation] = []
        switch state.mode {
        case .addBookmark:
            guard let url else { return false }
            operations.append(.create(.bookmark(state.title, url: url, in: state.folder), index: nil))
        case .addFolder:
            operations.append(.create(.folder(state.title, in: state.folder), index: nil))
        case .edit(let id):
            guard let node = tree.node(id) else { return true }
            operations.append(.update(id: id, title: state.title == node.title ? nil : state.title,
                                      url: url == node.url ? nil : url))
            if state.folder != node.parent {
                operations.append(.move(id: id, parent: state.folder, index: tree.children(of: state.folder).count))
            }
        }
        for operation in operations where source?.apply(operation) == false { return false }
        editor = nil
        errorMessage = nil
        reload()
        return true
    }

    public func delete(_ ids: Set<String>) {
        // Parents first would delete children twice; drop ids under another selected id.
        let roots = ids.filter { id in !ids.contains { $0 != id && tree.isDescendant(id, of: $0) } }
        for id in roots { source?.apply(.delete(id: id)) }
        selection.subtract(ids)
        reload()
    }

    /// Moves `id` into `parent` at `index` (nil: the end).
    public func move(_ id: String, into parent: String, at index: Int? = nil) {
        guard tree.node(id) != nil, id != parent else { return }
        let target = index ?? tree.children(of: parent).filter { $0.id != id }.count
        source?.apply(.move(id: id, parent: parent, index: target))
        reload()
    }

    /// A row dropped on `target`: into it when it is a folder, else just before it.
    public func drop(_ id: String, on target: BookmarkNode) {
        guard id != target.id else { return }
        if target.isFolder, !tree.isDescendant(target.id, of: id) { return move(id, into: target.id) }
        var siblings = tree.children(of: target.parent).map(\.id)
        siblings.removeAll { $0 == id }
        move(id, into: target.parent, at: siblings.firstIndex(of: target.id) ?? siblings.count)
    }
}

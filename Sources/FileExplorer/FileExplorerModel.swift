import Foundation

// MARK: - FileExplorerItem

/// A single node in the file explorer tree — either a file or a directory.
struct FileExplorerItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    let isHidden: Bool
    var children: [FileExplorerItem]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.isHidden = url.lastPathComponent.hasPrefix(".")
    }

    /// SF Symbol name appropriate for this item's type.
    var iconName: String {
        if isDirectory { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "json": return "curlybraces"
        case "md", "markdown": return "doc.richtext"
        case "sh", "zsh", "bash": return "terminal"
        case "yml", "yaml", "toml", "plist", "xcconfig": return "gearshape"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico": return "photo"
        case "pdf": return "doc.text.image"
        case "zip", "tar", "gz", "bz2": return "archivebox"
        case "html", "htm", "css": return "globe"
        case "xcodeproj", "xcworkspace", "pbxproj": return "hammer"
        case "gitignore", "gitmodules": return "arrow.triangle.branch"
        case "lock": return "lock"
        case "log": return "doc.text.magnifyingglass"
        case "js", "jsx", "ts", "tsx", "py", "rb", "c", "cpp", "h", "hpp",
             "m", "mm", "rs", "go", "java", "kt":
            return "doc.text"
        default: return "doc"
        }
    }

    /// Path relative to a root URL, for context menu "Copy Relative Path".
    func relativePath(from root: URL?) -> String {
        guard let root else { return url.path }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if url.path.hasPrefix(rootPath) {
            return String(url.path.dropFirst(rootPath.count))
        }
        return url.path
    }

    static func == (lhs: FileExplorerItem, rhs: FileExplorerItem) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

// MARK: - FileExplorerModel

/// Loads and manages the file tree for a directory, with expansion tracking,
/// search filtering, and live FSEvents watching.
@MainActor
final class FileExplorerModel: ObservableObject {
    @Published var rootURL: URL?
    @Published var expandedDirectories: Set<URL> = []
    @Published var searchQuery: String = "" { didSet { recomputeFlatItems() } }
    @Published var showHiddenFiles: Bool = false { didSet { recomputeFlatItems() } }

    /// Flattened visible items ready for rendering — computed from tree + filters + expansion.
    @Published var flatDisplayItems: [FlatEntry] = []

    struct FlatEntry: Identifiable {
        let item: FileExplorerItem
        let depth: Int
        var id: URL { item.id }
    }

    private var rootItems: [FileExplorerItem] = []
    private let watcher = FileSystemWatcher()

    // MARK: - Public API

    func setRoot(_ url: URL) {
        guard url != rootURL else { return }
        rootURL = url
        expandedDirectories.removeAll()
        loadRoot()
        watcher.start(watching: url) { [weak self] in
            self?.refresh()
        }
    }

    func toggleExpansion(_ item: FileExplorerItem) {
        guard item.isDirectory else { return }
        if expandedDirectories.contains(item.url) {
            expandedDirectories.remove(item.url)
        } else {
            expandedDirectories.insert(item.url)
            loadChildrenIfNeeded(for: item.url)
        }
        recomputeFlatItems()
    }

    func isExpanded(_ item: FileExplorerItem) -> Bool {
        expandedDirectories.contains(item.url)
    }

    func refresh() {
        loadRoot()
    }

    func stopWatching() {
        watcher.stop()
    }

    /// Display name for the root directory (e.g. "~/Projects/cmux").
    var rootDisplayName: String {
        guard let root = rootURL else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if root.path.hasPrefix(home) {
            return "~" + root.path.dropFirst(home.count)
        }
        return root.path
    }

    // MARK: - Loading

    private func loadRoot() {
        guard let rootURL else {
            rootItems = []
            recomputeFlatItems()
            return
        }
        rootItems = loadDirectory(rootURL)
        rootItems = rootItems.map { reloadAllExpanded(in: $0) }
        recomputeFlatItems()
    }

    private func loadDirectory(_ url: URL) -> [FileExplorerItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        return urls.compactMap { childURL in
            let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return FileExplorerItem(url: childURL, isDirectory: isDir)
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            if a.isHidden != b.isHidden { return !a.isHidden }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func loadChildrenIfNeeded(for directoryURL: URL) {
        rootItems = rootItems.map { updateChildren(in: $0, targetURL: directoryURL, forceReload: false) }
    }

    /// Single parameterized tree walk for both lazy-loading and reloading children.
    private func updateChildren(in item: FileExplorerItem, targetURL: URL, forceReload: Bool) -> FileExplorerItem {
        if item.url == targetURL && item.isDirectory && (forceReload || item.children == nil) {
            var updated = item
            updated.children = loadDirectory(targetURL)
            return updated
        }
        guard item.isDirectory, let children = item.children else { return item }
        var updated = item
        updated.children = children.map { updateChildren(in: $0, targetURL: targetURL, forceReload: forceReload) }
        return updated
    }

    /// Single-pass reload of all expanded directories — O(n) instead of O(E * N).
    private func reloadAllExpanded(in item: FileExplorerItem) -> FileExplorerItem {
        guard item.isDirectory else { return item }
        var updated = item
        if expandedDirectories.contains(item.url) {
            updated.children = loadDirectory(item.url)
        }
        if let children = updated.children {
            updated.children = children.map { reloadAllExpanded(in: $0) }
        }
        return updated
    }

    // MARK: - Filtering & flattening

    private func recomputeFlatItems() {
        var filtered = rootItems
        if !showHiddenFiles {
            filtered = filterHidden(filtered)
        }
        if !searchQuery.isEmpty {
            filtered = filterByQuery(filtered, query: searchQuery.lowercased())
        }
        flatDisplayItems = flatten(filtered, depth: 0)
    }

    private func filterHidden(_ items: [FileExplorerItem]) -> [FileExplorerItem] {
        items.compactMap { item in
            guard !item.isHidden else { return nil }
            guard item.isDirectory, let children = item.children else { return item }
            var updated = item
            updated.children = filterHidden(children)
            return updated
        }
    }

    private func filterByQuery(_ items: [FileExplorerItem], query: String) -> [FileExplorerItem] {
        items.compactMap { item in
            let nameMatches = item.name.lowercased().contains(query)
            if item.isDirectory, let children = item.children {
                let filteredChildren = filterByQuery(children, query: query)
                if nameMatches || !filteredChildren.isEmpty {
                    var updated = item
                    updated.children = filteredChildren
                    return updated
                }
                return nil
            }
            return nameMatches ? item : nil
        }
    }

    private func flatten(_ items: [FileExplorerItem], depth: Int) -> [FlatEntry] {
        var result: [FlatEntry] = []
        for item in items {
            result.append(FlatEntry(item: item, depth: depth))
            if item.isDirectory && expandedDirectories.contains(item.url), let children = item.children {
                result.append(contentsOf: flatten(children, depth: depth + 1))
            }
        }
        return result
    }
}

import Foundation

/// A single node in the file explorer tree (file or directory).
struct FileExplorerNode: Identifiable, Equatable {
    /// Unique ID derived from the relative path to the root.
    let id: String
    /// Display name (filename or directory name).
    let name: String
    /// Whether this node is a directory.
    let isDirectory: Bool
    /// Absolute URL on disk.
    let url: URL
    /// Child nodes. `nil` = not yet loaded, `[]` = empty directory.
    var children: [FileExplorerNode]?
    /// Whether the directory is expanded in the tree.
    var isExpanded: Bool = false

    static func == (lhs: FileExplorerNode, rhs: FileExplorerNode) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.isDirectory == rhs.isDirectory
            && lhs.isExpanded == rhs.isExpanded
            && lhs.children?.map(\.id) == rhs.children?.map(\.id)
    }
}

// MARK: - Icon mapping

extension FileExplorerNode {
    /// SF Symbol name for this node's file type.
    var iconName: String {
        if isDirectory {
            return isExpanded ? "folder.fill" : "folder"
        }
        return Self.iconForExtension(url.pathExtension.lowercased())
    }

    private static func iconForExtension(_ ext: String) -> String {
        switch ext {
        // Code
        case "swift", "ts", "tsx", "js", "jsx", "py", "rb", "go", "rs", "java", "c", "cpp", "h":
            return "doc.text"
        // Markup / docs
        case "md", "mdx":
            return "doc.richtext"
        case "html", "htm", "xml", "svg":
            return "globe"
        case "css", "scss", "less":
            return "paintbrush"
        // Config
        case "json", "yaml", "yml", "toml", "ini", "env", "plist":
            return "gearshape"
        // Images
        case "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "tiff":
            return "photo"
        // PDFs
        case "pdf":
            return "doc.richtext"
        // Archives
        case "zip", "tar", "gz", "bz2", "xz", "rar":
            return "archivebox"
        // Lock / generated
        case "lock":
            return "lock"
        default:
            return "doc"
        }
    }
}

// MARK: - Directory scanning

extension FileExplorerNode {
    /// Default directories and files to hide (matches common .gitignore patterns).
    private static let defaultHidden: Set<String> = [
        "node_modules", ".git", ".next", ".nuxt", ".svelte-kit",
        "__pycache__", ".pytest_cache", ".mypy_cache",
        ".DS_Store", "Thumbs.db",
        ".build", "DerivedData", ".swiftpm",
        "dist", "build", ".turbo", ".vercel",
        ".env.local", ".env.production",
    ]

    /// Scan a directory URL and return its children (one level deep).
    /// Filters out hidden entries by default.
    static func scanDirectory(
        at url: URL,
        relativeTo root: URL,
        showHidden: Bool = false
    ) -> [FileExplorerNode] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { itemURL in
                showHidden || !defaultHidden.contains(itemURL.lastPathComponent)
            }
            .map { itemURL in
                let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let relativePath = itemURL.path.replacingOccurrences(of: root.path, with: "")
                return FileExplorerNode(
                    id: relativePath,
                    name: itemURL.lastPathComponent,
                    isDirectory: isDir,
                    url: itemURL,
                    children: isDir ? nil : []  // nil signals "not loaded yet" for dirs
                )
            }
            .sorted { lhs, rhs in
                // Directories first, then alphabetical
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

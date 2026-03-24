import SwiftUI
import AppKit

// MARK: - Data Model

/// Represents a file/directory entry in the explorer tree.
@MainActor
final class FileNode: ObservableObject, Identifiable {
    let id = UUID()
    let name: String
    let relativePath: String
    let rootPath: String
    let isDirectory: Bool
    @Published var children: [FileNode]?
    @Published var isExpanded: Bool = false
    @Published var gitStatus: String?
    @Published var isIgnored: Bool = false

    var absolutePath: String {
        rootPath.isEmpty ? relativePath : (rootPath as NSString).appendingPathComponent(relativePath)
    }

    init(name: String, relativePath: String, rootPath: String, isDirectory: Bool) {
        self.name = name
        self.relativePath = relativePath
        self.rootPath = rootPath
        self.isDirectory = isDirectory
    }
}

/// Manages the file tree for a single root directory.
@MainActor
final class FileTreeRoot: ObservableObject, Identifiable {
    let id = UUID()
    let path: String
    var name: String { (path as NSString).lastPathComponent }
    @Published var children: [FileNode] = []
    @Published var isExpanded: Bool = true
    @Published var gitStatusMap: [String: String] = [:]
    @Published var gitIgnoredPaths: Set<String> = []

    private var fsEventStream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?

    var onChanged: (() -> Void)?

    init(path: String) {
        self.path = path
        loadChildren()
        loadGitStatus()
        startFSEvents()
    }

    deinit {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func loadChildren() {
        children = Self.loadEntries(at: path, relativeTo: "", rootPath: path, gitStatusMap: gitStatusMap, gitIgnoredPaths: gitIgnoredPaths)
    }

    func loadChildrenForNode(_ node: FileNode) {
        node.children = Self.loadEntries(
            at: (node.rootPath as NSString).appendingPathComponent(node.relativePath),
            relativeTo: node.relativePath,
            rootPath: node.rootPath,
            gitStatusMap: gitStatusMap,
            gitIgnoredPaths: gitIgnoredPaths
        )
    }

    static func loadEntries(
        at directoryPath: String,
        relativeTo parentRelative: String,
        rootPath: String,
        gitStatusMap: [String: String],
        gitIgnoredPaths: Set<String>
    ) -> [FileNode] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directoryPath) else { return [] }

        return entries
            .filter { $0 != ".git" }
            .sorted { lhs, rhs in
                let lhsPath = (directoryPath as NSString).appendingPathComponent(lhs)
                let rhsPath = (directoryPath as NSString).appendingPathComponent(rhs)
                var lhsIsDir: ObjCBool = false
                var rhsIsDir: ObjCBool = false
                fm.fileExists(atPath: lhsPath, isDirectory: &lhsIsDir)
                fm.fileExists(atPath: rhsPath, isDirectory: &rhsIsDir)
                if lhsIsDir.boolValue != rhsIsDir.boolValue { return lhsIsDir.boolValue }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .map { entryName in
                let entryPath = (directoryPath as NSString).appendingPathComponent(entryName)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: entryPath, isDirectory: &isDir)
                let relativePath = parentRelative.isEmpty ? entryName : parentRelative + "/" + entryName
                let node = FileNode(name: entryName, relativePath: relativePath, rootPath: rootPath, isDirectory: isDir.boolValue)

                // Apply git status
                if let status = gitStatusMap[relativePath] {
                    node.gitStatus = status
                }
                // Check ignored
                if gitIgnoredPaths.contains(relativePath) || isParentIgnored(relativePath, in: gitIgnoredPaths) {
                    node.isIgnored = true
                }
                // Folder git status: bubble up from children
                if isDir.boolValue {
                    node.gitStatus = folderGitStatus(relativePath, gitStatusMap: gitStatusMap)
                    if node.isIgnored {
                        node.gitStatus = "ignored"
                    }
                }

                return node
            }
    }

    private static func isParentIgnored(_ path: String, in ignoredPaths: Set<String>) -> Bool {
        let parts = path.split(separator: "/")
        for i in 1..<parts.count {
            let parent = parts.prefix(i).joined(separator: "/")
            if ignoredPaths.contains(parent) { return true }
        }
        return false
    }

    private static func folderGitStatus(
        _ folderPath: String,
        gitStatusMap: [String: String]
    ) -> String? {
        let prefix = folderPath + "/"
        let priority: [String: Int] = [
            "conflict": 6, "modified": 5, "deleted": 4,
            "added": 3, "untracked": 2, "renamed": 1
        ]
        var best: String?
        var bestPriority = 0
        for (path, status) in gitStatusMap {
            if path.hasPrefix(prefix) {
                let p = priority[status] ?? 0
                if p > bestPriority { best = status; bestPriority = p }
            }
        }
        return best
    }

    func loadGitStatus() {
        DispatchQueue.global(qos: .userInitiated).async { [path] in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path, "status", "--porcelain=v1", "-unormal", "--ignored"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            guard (try? process.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""

            var statusMap: [String: String] = [:]
            var ignoredPaths: Set<String> = []

            for line in output.components(separatedBy: "\n") where line.count >= 3 {
                let index = String(line[line.index(line.startIndex, offsetBy: 0)])
                let workTree = String(line[line.index(line.startIndex, offsetBy: 1)])
                var filePath = String(line[line.index(line.startIndex, offsetBy: 3)...])
                if filePath.hasSuffix("/") { filePath = String(filePath.dropLast()) }
                if filePath.contains(" -> ") { filePath = filePath.components(separatedBy: " -> ").last ?? filePath }

                if index == "!" && workTree == "!" {
                    ignoredPaths.insert(filePath)
                    continue
                }

                let status: String
                if index == "?" && workTree == "?" { status = "untracked" }
                else if index == "U" || workTree == "U" || (index == "A" && workTree == "A") || (index == "D" && workTree == "D") { status = "conflict" }
                else if index == "A" || workTree == "A" { status = "added" }
                else if index == "D" || workTree == "D" { status = "deleted" }
                else if index == "R" { status = "renamed" }
                else { status = "modified" }

                statusMap[filePath] = status
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.gitStatusMap = statusMap
                self.gitIgnoredPaths = ignoredPaths
                // Update git status on existing nodes in-place (no tree rebuild)
                self.updateGitStatusInPlace(nodes: self.children)
            }
        }
    }

    /// Recursively update git status on existing nodes without rebuilding the tree.
    private func updateGitStatusInPlace(nodes: [FileNode]) {
        for node in nodes {
            let isIgnored = gitIgnoredPaths.contains(node.relativePath) ||
                Self.isParentIgnored(node.relativePath, in: gitIgnoredPaths)
            node.isIgnored = isIgnored

            if node.isDirectory {
                if isIgnored {
                    node.gitStatus = "ignored"
                } else {
                    node.gitStatus = Self.folderGitStatus(node.relativePath, gitStatusMap: gitStatusMap)
                }
                if let children = node.children {
                    updateGitStatusInPlace(nodes: children)
                }
            } else {
                node.gitStatus = gitStatusMap[node.relativePath]
            }
        }
    }

    /// Check if directory entries changed (files added/removed) and reload only if needed.
    func refreshStructureIfNeeded() {
        let fm = FileManager.default
        let currentEntries = Set((try? fm.contentsOfDirectory(atPath: path))?.filter { $0 != ".git" } ?? [])
        let knownEntries = Set(children.map(\.name))
        if currentEntries != knownEntries {
            loadChildren()
        }
        // Also check expanded subdirectories
        for child in children where child.isDirectory && child.isExpanded {
            refreshNodeStructureIfNeeded(child)
        }
    }

    private func refreshNodeStructureIfNeeded(_ node: FileNode) {
        let fullPath = (node.rootPath as NSString).appendingPathComponent(node.relativePath)
        let fm = FileManager.default
        let currentEntries = Set((try? fm.contentsOfDirectory(atPath: fullPath))?.filter { $0 != ".git" } ?? [])
        let knownEntries = Set(node.children?.map(\.name) ?? [])
        if currentEntries != knownEntries {
            loadChildrenForNode(node)
        }
        for child in (node.children ?? []) where child.isDirectory && child.isExpanded {
            refreshNodeStructureIfNeeded(child)
        }
    }

    // MARK: - FSEvents

    private func startFSEvents() {
        let paths = [path] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let root = Unmanaged<FileTreeRoot>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async {
                root.debouncedRefresh()
            }
        }

        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, UInt32(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        fsEventStream = stream
    }

    private func debouncedRefresh() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshStructureIfNeeded()
            self.loadGitStatus()
            self.onChanged?()
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}

// MARK: - File Explorer View Model

@MainActor
final class NativeFileExplorerViewModel: ObservableObject {
    @Published var roots: [FileTreeRoot] = []
    var onOpenFile: ((String) -> Void)?
    var onPinFile: ((String) -> Void)?

    func updateRootPaths(_ paths: [String]) {
        let existingByPath = Dictionary(uniqueKeysWithValues: roots.map { ($0.path, $0) })
        var newRoots: [FileTreeRoot] = []
        for path in paths {
            if let existing = existingByPath[path] {
                newRoots.append(existing)
            } else {
                let root = FileTreeRoot(path: path)
                newRoots.append(root)
            }
        }
        roots = newRoots
    }

    func toggleExpand(_ node: FileNode, in root: FileTreeRoot) {
        node.isExpanded.toggle()
        if node.isExpanded && node.children == nil {
            root.loadChildrenForNode(node)
        }
    }
}

// MARK: - Views

struct NativeFileExplorerView: View {
    @ObservedObject var viewModel: NativeFileExplorerViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if viewModel.roots.count == 1 {
                        // Single root: show files directly
                        ForEach(viewModel.roots[0].children) { node in
                            FileNodeRow(node: node, root: viewModel.roots[0], depth: 0, viewModel: viewModel)
                        }
                    } else {
                        // Multi-root: collapsible root headers
                        ForEach(viewModel.roots) { root in
                            RootHeaderRow(root: root)
                            if root.isExpanded {
                                ForEach(root.children) { node in
                                    FileNodeRow(node: node, root: root, depth: 1, viewModel: viewModel)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct RootHeaderRow: View {
    @ObservedObject var root: FileTreeRoot

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: root.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 16)
                .foregroundStyle(.secondary)

            Image(systemName: root.isExpanded ? "folder.fill" : "folder")
                .font(.system(size: 13))
                .foregroundColor(Color(nsColor: NSColor(red: 0.86, green: 0.71, blue: 0.48, alpha: 1)))
                .frame(width: 16)

            Text(root.name)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.3)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                root.isExpanded.toggle()
            }
        }
    }
}

struct FileNodeRow: View {
    @ObservedObject var node: FileNode
    let root: FileTreeRoot
    let depth: Int
    let viewModel: NativeFileExplorerViewModel
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Indent
            ForEach(0..<depth, id: \.self) { _ in
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 1)
                    .padding(.horizontal, 3.5)
                    .frame(width: 8)
            }

            // Twistie
            if node.isDirectory {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
            } else {
                Spacer().frame(width: 16)
            }

            // Icon
            FileIconView(name: node.name, isDirectory: node.isDirectory, isExpanded: node.isExpanded)
                .frame(width: 16)
                .padding(.trailing, 6)

            // Name
            Text(node.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundStyle(labelColor)
                .strikethrough(node.gitStatus == "deleted" && !node.isDirectory, color: gitColor)

            Spacer()

            // Git badge
            if let status = node.gitStatus, status != "ignored" {
                if node.isDirectory {
                    Circle()
                        .fill(gitColor)
                        .frame(width: 6, height: 6)
                        .padding(.trailing, 4)
                } else {
                    Text(gitBadgeLetter)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(gitColor)
                        .padding(.trailing, 4)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Color.white.opacity(0.05) : Color.clear)
        .opacity(node.isIgnored ? 0.4 : 1.0)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if node.isDirectory {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.toggleExpand(node, in: root)
                }
            } else {
                viewModel.onOpenFile?(node.absolutePath)
            }
        }
        .onTapGesture(count: 2) {
            if !node.isDirectory {
                viewModel.onPinFile?(node.absolutePath)
            }
        }

        // Children
        if node.isDirectory && node.isExpanded {
            if let children = node.children {
                ForEach(children) { child in
                    FileNodeRow(node: child, root: root, depth: depth + 1, viewModel: viewModel)
                }
            }
        }
    }

    private var labelColor: Color {
        guard let status = node.gitStatus else { return .primary }
        return gitColor
    }

    private var gitColor: Color {
        switch node.gitStatus {
        case "modified": return Color(nsColor: NSColor(red: 0.89, green: 0.75, blue: 0.55, alpha: 1))
        case "added": return Color(nsColor: NSColor(red: 0.51, green: 0.72, blue: 0.55, alpha: 1))
        case "deleted": return Color(nsColor: NSColor(red: 0.78, green: 0.31, blue: 0.22, alpha: 1))
        case "untracked": return Color(nsColor: NSColor(red: 0.45, green: 0.79, blue: 0.57, alpha: 1))
        case "renamed": return Color(nsColor: NSColor(red: 0.45, green: 0.79, blue: 0.57, alpha: 1))
        case "conflict": return Color(nsColor: NSColor(red: 0.89, green: 0.40, blue: 0.42, alpha: 1))
        case "ignored": return .gray
        default: return .primary
        }
    }

    private var gitBadgeLetter: String {
        switch node.gitStatus {
        case "modified": return "M"
        case "added": return "A"
        case "deleted": return "D"
        case "untracked": return "U"
        case "renamed": return "R"
        case "conflict": return "!"
        default: return ""
        }
    }
}

struct FileIconView: View {
    let name: String
    let isDirectory: Bool
    let isExpanded: Bool

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 13))
            .foregroundColor(iconColor)
    }

    private var iconName: String {
        if isDirectory { return isExpanded ? "folder.fill" : "folder" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "js", "jsx", "mjs", "cjs", "ts", "tsx": return "doc.text"
        case "json": return "curlybraces"
        case "md", "markdown": return "doc.richtext"
        case "py": return "doc.text"
        case "html", "htm": return "globe"
        case "css", "scss", "less": return "paintbrush"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        case "sh", "bash", "zsh": return "terminal"
        default: return "doc"
        }
    }

    private var iconColor: Color {
        if isDirectory { return Color(nsColor: NSColor(red: 0.86, green: 0.71, blue: 0.48, alpha: 1)) }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .orange
        case "js", "jsx", "mjs", "cjs": return Color(nsColor: NSColor(red: 0.90, green: 0.80, blue: 0.41, alpha: 1))
        case "ts", "tsx": return Color(nsColor: NSColor(red: 0.19, green: 0.47, blue: 0.78, alpha: 1))
        case "py": return Color(nsColor: NSColor(red: 0.21, green: 0.45, blue: 0.65, alpha: 1))
        case "rs": return Color(nsColor: NSColor(red: 0.87, green: 0.65, blue: 0.52, alpha: 1))
        case "go": return .cyan
        case "html", "htm": return Color(nsColor: NSColor(red: 0.89, green: 0.30, blue: 0.15, alpha: 1))
        case "css", "scss": return Color(nsColor: NSColor(red: 0.34, green: 0.24, blue: 0.49, alpha: 1))
        case "json": return Color(nsColor: NSColor(red: 0.90, green: 0.80, blue: 0.41, alpha: 1))
        case "md", "markdown": return Color(nsColor: NSColor(red: 0.32, green: 0.60, blue: 0.73, alpha: 1))
        case "sh", "bash", "zsh": return Color(nsColor: NSColor(red: 0.54, green: 0.88, blue: 0.32, alpha: 1))
        default: return .secondary
        }
    }
}

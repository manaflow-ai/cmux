import SwiftUI
import Foundation

/// A file browser tree view that displays the contents of a directory.
struct FileBrowserView: View {
    let rootPath: String
    let onFileSelected: (String) -> Void

    @StateObject private var coordinator = FileBrowserCoordinator()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(coordinator.flattenedEntries) { item in
                    fileBrowserRow(item: item)
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear {
            coordinator.setRootPath(rootPath)
        }
        .onDisappear {
            coordinator.reset()
        }
        .onChange(of: rootPath) { newPath in
            coordinator.setRootPath(newPath)
        }
    }

    // MARK: - Row view

    private func fileBrowserRow(item: FileBrowserFlatItem) -> some View {
        let entry = item.entry
        return Button {
            if entry.isDirectory {
                coordinator.toggleDirectory(entry.path)
            } else {
                onFileSelected(entry.path)
            }
        } label: {
            HStack(spacing: 4) {
                if entry.isDirectory {
                    Image(systemName: coordinator.expandedDirectories.contains(entry.path) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                } else {
                    Color.clear.frame(width: 12)
                }
                Image(systemName: entry.isDirectory ? "folder.fill" : fileIcon(for: entry.name))
                    .font(.system(size: 12))
                    .foregroundColor(entry.isDirectory ? .accentColor : .secondary)
                    .frame(width: 16)
                Text(entry.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.leading, CGFloat(item.depth) * 16 + 8)
            .padding(.vertical, 3)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - File icons

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "py", "js", "ts", "rb", "go", "rs", "c", "cpp", "h", "m", "java", "kt", "zig":
            return "doc.text"
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return "doc.badge.gearshape"
        case "md", "markdown", "txt", "rtf":
            return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg", "ico", "webp":
            return "photo"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }
}

// MARK: - Flat item for non-recursive rendering

struct FileBrowserFlatItem: Identifiable {
    let entry: FileBrowserEntry
    let depth: Int
    var id: String { "\(depth):\(entry.path)" }
}

// MARK: - Coordinator (reference type for DispatchSource safety)

@MainActor
final class FileBrowserCoordinator: ObservableObject {
    @Published var rootEntries: [FileBrowserEntry] = []
    @Published var expandedDirectories: Set<String> = []
    @Published var directoryContents: [String: [FileBrowserEntry]] = [:]

    private var currentRootPath: String?
    private nonisolated(unsafe) var directoryWatchSource: DispatchSourceFileSystemObject?
    private var rootLoadGeneration: UInt64 = 0

    private static let loadQueue = DispatchQueue(label: "com.cmux.file-browser", qos: .userInitiated)

    /// Flattened tree for non-recursive ForEach rendering.
    var flattenedEntries: [FileBrowserFlatItem] {
        var result: [FileBrowserFlatItem] = []
        func flatten(_ entries: [FileBrowserEntry], depth: Int) {
            for entry in entries {
                result.append(FileBrowserFlatItem(entry: entry, depth: depth))
                if entry.isDirectory && expandedDirectories.contains(entry.path),
                   let children = directoryContents[entry.path] {
                    flatten(children, depth: depth + 1)
                }
            }
        }
        flatten(rootEntries, depth: 0)
        return result
    }

    func setRootPath(_ path: String) {
        guard path != currentRootPath else { return }
        currentRootPath = path
        expandedDirectories.removeAll()
        directoryContents.removeAll()
        stopDirectoryWatcher()
        loadRootDirectory()
        startDirectoryWatcher()
    }

    func toggleDirectory(_ path: String) {
        if expandedDirectories.contains(path) {
            expandedDirectories.remove(path)
        } else {
            expandedDirectories.insert(path)
            loadSubdirectory(path)
        }
    }

    // MARK: - Directory loading

    private func loadRootDirectory() {
        guard let path = currentRootPath else { return }
        rootLoadGeneration &+= 1
        let generation = rootLoadGeneration
        Self.loadQueue.async { [weak self] in
            let entries = FileBrowserCoordinator.loadDirectorySync(atPath: path, showHidden: true)
            DispatchQueue.main.async {
                guard let self, generation == self.rootLoadGeneration else { return }
                self.rootEntries = entries
            }
        }
    }

    private func loadSubdirectory(_ path: String) {
        Self.loadQueue.async { [weak self] in
            let entries = FileBrowserCoordinator.loadDirectorySync(atPath: path, showHidden: true)
            DispatchQueue.main.async {
                guard let self, self.expandedDirectories.contains(path) else { return }
                self.directoryContents[path] = entries
            }
        }
    }

    /// Pure function — safe to call from any thread.
    nonisolated static func loadDirectorySync(atPath path: String, showHidden: Bool) -> [FileBrowserEntry] {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return []
        }

        var dirs: [FileBrowserEntry] = []
        var files: [FileBrowserEntry] = []

        for name in contents {
            if !showHidden && name.hasPrefix(".") { continue }

            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }

            let entry = FileBrowserEntry(name: name, path: fullPath, isDirectory: isDir.boolValue)
            if isDir.boolValue {
                dirs.append(entry)
            } else {
                files.append(entry)
            }
        }

        dirs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        files.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return dirs + files
    }

    // MARK: - Directory watcher

    func startDirectoryWatcher() {
        guard let path = currentRootPath else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: Self.loadQueue
        )

        source.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadRootDirectory()
                for dir in self.expandedDirectories {
                    self.loadSubdirectory(dir)
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        directoryWatchSource = source
    }

    func stopDirectoryWatcher() {
        directoryWatchSource?.cancel()
        directoryWatchSource = nil
    }

    /// Called on disappear — clears root path so reappear with same path re-arms.
    func reset() {
        stopDirectoryWatcher()
        currentRootPath = nil
    }

    deinit {
        directoryWatchSource?.cancel()
    }
}

struct FileBrowserEntry: Identifiable {
    let name: String
    let path: String
    let isDirectory: Bool
    var id: String { path }
}

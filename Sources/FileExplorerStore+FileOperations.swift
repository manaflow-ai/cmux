import AppKit
import CmuxFileTree
import Foundation

/// Finder-style mutations for local roots: new file and folder, rename,
/// Move to Trash and drops. File I/O runs off the main actor; the tree
/// updates through the normal refresh path (and FSEvents confirms it).
@MainActor
extension FileExplorerStore {
    enum FileOperationError: LocalizedError {
        case unsupported
        case invalidName
        case alreadyExists(String)

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return String(localized: "fileExplorer.operation.unsupported", defaultValue: "This action is only available for files on this Mac.")
            case .invalidName:
                return String(localized: "fileExplorer.operation.invalidName", defaultValue: "Names cannot be empty or contain “/” or “:”.")
            case .alreadyExists(let name):
                return String(
                    format: String(localized: "fileExplorer.operation.alreadyExists", defaultValue: "The name “%@” is already taken. Choose a different name."),
                    name
                )
            }
        }
    }

    /// Creates `untitled folder` / `untitled file` in `directory`, then starts
    /// inline rename once the row appears.
    @discardableResult
    func createItem(inDirectory directory: String, isFolder: Bool) async throws -> String {
        guard supportsFileOperations else { throw FileOperationError.unsupported }
        let baseName = isFolder
            ? String(localized: "fileExplorer.newFolder.defaultName", defaultValue: "untitled folder")
            : String(localized: "fileExplorer.newFile.defaultName", defaultValue: "untitled file")
        let path = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let target = FileExplorerFileNaming.uniquePath(in: directory, preferredName: baseName, fileManager: fm)
            if isFolder {
                try fm.createDirectory(atPath: target, withIntermediateDirectories: false)
            } else {
                guard fm.createFile(atPath: target, contents: Data()) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            return target
        }.value
        pendingRenamePath = path
        revealDirectoryAndRefresh(directory)
        return path
    }

    /// Renames a local item in place and keeps it selected.
    @discardableResult
    func renameItem(atPath path: String, to proposedName: String) async throws -> String {
        guard supportsFileOperations else { throw FileOperationError.unsupported }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), name != ".", name != ".." else {
            throw FileOperationError.invalidName
        }
        let parent = (path as NSString).deletingLastPathComponent
        let destination = (parent as NSString).appendingPathComponent(name)
        guard destination != path else { return path }
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            // A case-only rename on a case-insensitive volume reports the
            // destination as existing; it is the same item.
            if fm.fileExists(atPath: destination),
               path.lowercased() != destination.lowercased() {
                throw FileOperationError.alreadyExists(name)
            }
            try fm.moveItem(atPath: path, toPath: destination)
        }.value
        if expandedPaths.remove(path) != nil {
            expandedPaths.insert(destination)
        }
        selectedPath = destination
        selectedPaths = [destination]
        revealDirectoryAndRefresh(parent)
        return destination
    }

    /// Moves items to the Trash through NSWorkspace, like Finder.
    func moveToTrash(paths: [String]) async throws {
        guard supportsFileOperations else { throw FileOperationError.unsupported }
        guard !paths.isEmpty else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle(urls) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        // Keep the keyboard anchor near the removed rows.
        if let first = paths.first, let node = nodesByPath[first], let parent = node.parent {
            selectedPath = parent.path
            selectedPaths = [parent.path]
        }
        handleChangedDirectories(Set(paths.map { ($0 as NSString).deletingLastPathComponent }))
    }

    /// Copies or moves dropped file URLs into `directory`, keeping both when
    /// a name is taken (Finder's “Keep Both”).
    @discardableResult
    func importItems(_ urls: [URL], into directory: String, move: Bool) async throws -> [String] {
        guard supportsFileOperations else { throw FileOperationError.unsupported }
        let sources = urls.filter(\.isFileURL).map(\.path).filter { source in
            // Never drop a folder into itself or its own subtree.
            !Self.path(directory, isContainedIn: source)
        }
        guard !sources.isEmpty else { return [] }
        let results = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var created: [String] = []
            for source in sources {
                let name = (source as NSString).lastPathComponent
                if move, (source as NSString).deletingLastPathComponent == directory { continue }
                let target = FileExplorerFileNaming.uniquePath(in: directory, preferredName: name, fileManager: fm)
                if move {
                    try fm.moveItem(atPath: source, toPath: target)
                } else {
                    try fm.copyItem(atPath: source, toPath: target)
                }
                created.append(target)
            }
            return created
        }.value
        var changed: Set<String> = [directory]
        if move {
            for source in sources { changed.insert((source as NSString).deletingLastPathComponent) }
        }
        revealDirectoryAndRefresh(directory)
        handleChangedDirectories(changed)
        if let first = results.first {
            selectedPath = first
            selectedPaths = Set(results)
        }
        return results
    }

    /// Expands `directory` if it is a collapsed row and re-lists it now,
    /// without waiting for the FSEvents latency.
    func revealDirectoryAndRefresh(_ directory: String) {
        if directory != rootPath, let node = nodesByPath[directory] {
            if !expandedPaths.contains(directory) {
                expand(node: node)
                notifyObservers { $0.fileExplorerTree(self, expand: [node]) }
            }
            node.isStale = true
        }
        handleChangedDirectories([directory])
    }
}

/// Finder's collision naming: `name`, `name 2`, `name 3`, before the extension.
struct FileExplorerFileNaming {
    static func uniquePath(in directory: String, preferredName: String, fileManager: FileManager) -> String {
        let first = (directory as NSString).appendingPathComponent(preferredName)
        guard fileManager.fileExists(atPath: first) else { return first }
        let ext = (preferredName as NSString).pathExtension
        let stem = ext.isEmpty ? preferredName : (preferredName as NSString).deletingPathExtension
        var counter = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            let candidate = (directory as NSString).appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate) { return candidate }
            counter += 1
        }
    }
}

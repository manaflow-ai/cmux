import AppKit
import Foundation

struct WorkspaceFinderDirectoryCacheKey: Equatable, Sendable {
    var path: String?
}

struct WorkspaceFinderDirectoryCache: Equatable, Sendable {
    var key: WorkspaceFinderDirectoryCacheKey? = nil
    var directoryURL: URL? = nil

    func url(for currentKey: WorkspaceFinderDirectoryCacheKey) -> URL? {
        guard key == currentKey else { return nil }
        return directoryURL
    }
}

struct WorkspaceFinderDirectoryOpenRequest: Equatable, Sendable {
    var id = UUID()
    var directoryURL: URL?
}

enum WorkspaceFinderDirectoryResolver {
    @MainActor
    static func path(for workspace: Workspace) -> String? {
        guard let directory = workspace.sidebarFinderDirectory() else { return nil }
        let path = NSString(string: directory).expandingTildeInPath
        return path.isEmpty ? nil : path
    }

    static func cache(for key: WorkspaceFinderDirectoryCacheKey) async -> WorkspaceFinderDirectoryCache {
        guard let path = key.path else { return WorkspaceFinderDirectoryCache(key: key) }
        let directoryURL = await existingDirectoryURL(for: path)
        return WorkspaceFinderDirectoryCache(key: key, directoryURL: directoryURL)
    }

    static func existingDirectoryURL(for path: String) async -> URL? {
        guard !Task.isCancelled else { return nil }
        let directoryURL = await Task.detached(priority: .utility) {
            existingDirectoryURLUnchecked(for: path)
        }.value
        guard !Task.isCancelled else { return nil }
        return directoryURL
    }

    private nonisolated static func existingDirectoryURLUnchecked(for path: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

enum WorkspaceFinderDirectoryOpener {
    @MainActor
    static func openInFinder(_ directoryURL: URL?) async {
        guard !Task.isCancelled else { return }
        guard let directoryURL else {
            NSSound.beep()
            return
        }
        if let refreshedURL = await WorkspaceFinderDirectoryResolver.existingDirectoryURL(for: directoryURL.path) {
            guard !Task.isCancelled else { return }
            NSWorkspace.shared.activateFileViewerSelecting([refreshedURL])
        } else {
            guard !Task.isCancelled else { return }
            NSSound.beep()
        }
    }
}

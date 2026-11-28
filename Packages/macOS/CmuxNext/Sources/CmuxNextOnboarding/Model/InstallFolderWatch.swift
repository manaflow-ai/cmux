import Foundation

/// Calls `changed` when an entry appears, goes or is renamed in one of `folders`: a vnode watch on each folder. A
/// folder that does not exist yet (a fresh Mac's `~/.local/bin`) is watched through its nearest existing parent,
/// which wakes only to move the watch down; `changed` runs once the folder itself exists or changes.
@MainActor
final class InstallFolderWatch {
    private let folders: [String]
    private let changed: @MainActor () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []

    init(folders: [URL], changed: @escaping @MainActor () -> Void) {
        self.folders = folders.map { $0.standardizedFileURL.path }
        self.changed = changed
        arm()
    }

    isolated deinit { cancel() }

    func cancel() {
        for source in sources { source.cancel() }
        sources = []
    }

    /// One watch per distinct path: each folder that exists, else its nearest existing parent, which stands for it.
    private func arm() {
        cancel()
        var standsFor: [String: [String]] = [:]
        for folder in folders {
            var path = folder
            while !FileManager.default.fileExists(atPath: path), path != "/" { path = (path as NSString).deletingLastPathComponent }
            standsFor[path, default: []].append(folder)
        }
        for (path, wanted) in standsFor {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fired(path: path, wanted: wanted) } }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    /// `path` changed: the watch moves to what exists now; `changed` runs when `path` is a wanted folder or one it
    /// stood for now exists (a parent's other changes, such as a dotfile saved in the home folder, run nothing).
    private func fired(path: String, wanted: [String]) {
        arm()
        if wanted.contains(path) || wanted.contains(where: { FileManager.default.fileExists(atPath: $0) }) { changed() }
    }
}

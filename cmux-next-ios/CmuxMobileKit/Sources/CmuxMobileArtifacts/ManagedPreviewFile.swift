import Foundation

/// Owns one downloaded snapshot. Content, viewers and thumbnail work retain this
/// object while reading; releasing the final reference removes only its folder.
public final class ManagedPreviewFile: Sendable {
    public let url: URL
    private let store: PreviewFileStore

    fileprivate init(url: URL, store: PreviewFileStore) {
        self.url = url
        self.store = store
    }

    deinit { store.remove(url.deletingLastPathComponent()) }

    /// Called off the main actor at launch. Active downloads/viewers are excluded,
    /// even if another scene starts while the sweep runs.
    public static func removeStaleCopies() { PreviewFileStore.shared.removeStaleCopies() }
}

/// The dedicated root contains only per-download UUID folders. Registration,
/// deletion and sweeping share a lock so a sweep cannot race a new download.
final class PreviewFileStore: @unchecked Sendable {
    static let shared = PreviewFileStore(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-mobile-preview-managed", isDirectory: true))
    let root: URL
    private let lock = NSLock()
    private var active: Set<String> = []

    init(root: URL) { self.root = root }

    func make(name: String) throws -> ManagedPreviewFile {
        try lock.withLock {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let id = UUID().uuidString
            let folder = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            active.insert(id)
            return ManagedPreviewFile(url: folder.appendingPathComponent(name), store: self)
        }
    }

    fileprivate func remove(_ folder: URL) {
        lock.withLock {
            try? FileManager.default.removeItem(at: folder)
            active.remove(folder.lastPathComponent)
        }
    }

    func removeStaleCopies() {
        lock.withLock {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
            guard let folders = try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: Array(keys)) else { return }
            for folder in folders {
                guard UUID(uuidString: folder.lastPathComponent) != nil,
                      !active.contains(folder.lastPathComponent),
                      let values = try? folder.resourceValues(forKeys: keys),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}

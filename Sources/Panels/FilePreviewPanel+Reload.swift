import CmuxFoundation
import Darwin

struct FilePreviewFileState: Equatable {
    private let exists: Bool
    private let device: dev_t
    private let inode: ino_t
    private let size: off_t
    private let modificationTime: timespec
    private let statusChangeTime: timespec

    static func capture(path: String) -> FilePreviewFileState {
        var attributes = stat()
        guard stat(path, &attributes) == 0 else {
            return FilePreviewFileState(
                exists: false,
                device: 0,
                inode: 0,
                size: 0,
                modificationTime: timespec(),
                statusChangeTime: timespec()
            )
        }
        return FilePreviewFileState(
            exists: true,
            device: attributes.st_dev,
            inode: attributes.st_ino,
            size: attributes.st_size,
            modificationTime: attributes.st_mtimespec,
            statusChangeTime: attributes.st_ctimespec
        )
    }

    static func == (lhs: FilePreviewFileState, rhs: FilePreviewFileState) -> Bool {
        lhs.exists == rhs.exists
            && lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.size == rhs.size
            && lhs.modificationTime.tv_sec == rhs.modificationTime.tv_sec
            && lhs.modificationTime.tv_nsec == rhs.modificationTime.tv_nsec
            && lhs.statusChangeTime.tv_sec == rhs.statusChangeTime.tv_sec
            && lhs.statusChangeTime.tv_nsec == rhs.statusChangeTime.tv_nsec
    }
}

extension FilePreviewPanel {
    /// Starts one panel-scoped filesystem observation task. `FileWatcher`
    /// handles atomic replacement and delete/recreate recovery for the path.
    func startWatchingForFileChanges() {
        stopWatchingForFileChanges()
        lastObservedFileState = .capture(path: filePath)
        let watcher = FileWatcher(path: filePath)
        fileChangeWatcher = watcher
        let events = watcher.events
        fileChangeTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self, !self.isClosed else { break }
                self.handleObservedFileChange()
            }
        }
    }

    @discardableResult
    func handleObservedFileChange() -> Task<Void, Never>? {
        let state = FilePreviewFileState.capture(path: filePath)
        guard state != lastObservedFileState else { return nil }
        lastObservedFileState = state
        return reloadFromDisk()
    }

    func stopWatchingForFileChanges() {
        fileChangeTask?.cancel()
        fileChangeTask = nil
        // Dropping the watcher cancels its DispatchSources.
        fileChangeWatcher = nil
    }
}

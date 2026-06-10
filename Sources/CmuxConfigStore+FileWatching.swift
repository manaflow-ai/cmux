import Bonsplit
import CmuxFileWatch
import Combine
import CryptoKit
import Foundation


// MARK: - File Watching
extension CmuxConfigStore {
    func startLocalFileWatcher() {
        guard let path = localConfigPath else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist yet — watch the directory instead
            startLocalDirectoryWatcher()
            return
        }
        localFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopLocalFileWatcher()
                    self.loadAll()
                    self.scheduleLocalReattach(attempt: 1)
                }
            } else {
                DispatchQueue.main.async {
                    self.loadAll()
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        localFileWatchSource = source
    }

    func updateLocalHookFileWatchers(
        paths: [String],
        primaryLocalPath: String?
    ) {
        let desiredPaths = Set(paths.filter { path in
            path != primaryLocalPath && FileManager.default.fileExists(atPath: path)
        })
        for path in Array(hookWatchers.keys) where !desiredPaths.contains(path) {
            stopLocalHookFileWatcher(at: path)
        }
        for path in desiredPaths where hookWatchers[path] == nil {
            startLocalHookFileWatcher(at: path)
        }
    }

    private func startLocalHookFileWatcher(at path: String) {
        let watcher = FileWatcher(path: path)
        hookWatchers[path] = watcher
        let events = watcher.events
        hookWatchTasks[path] = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                self.loadAll()
            }
        }
    }

    private func stopLocalHookFileWatcher(at path: String) {
        hookWatchTasks.removeValue(forKey: path)?.cancel()
        hookWatchers.removeValue(forKey: path)
    }

    private func stopLocalHookFileWatchers() {
        hookWatchTasks.values.forEach { $0.cancel() }
        hookWatchTasks.removeAll()
        hookWatchers.removeAll()
    }

    private func startLocalDirectoryWatcher() {
        guard let path = localConfigPath else { return }
        let configDirectory = (path as NSString).deletingLastPathComponent
        let fs = FileManager.default
        let dirPath: String
        if fs.fileExists(atPath: configDirectory) {
            dirPath = configDirectory
        } else if let searchDirectory = localConfigSearchDirectory,
                  fs.fileExists(atPath: searchDirectory) {
            dirPath = searchDirectory
        } else {
            dirPath = (configDirectory as NSString).deletingLastPathComponent
        }
        let eventHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.handleLocalDirectoryWatchEvent()
            }
        }

        guard let primaryWatch = startLocalDirectoryWatchSource(at: dirPath, eventHandler: eventHandler) else {
            return
        }
        localFileWatchSource = primaryWatch.source
        localFileDescriptor = primaryWatch.fileDescriptor

        if let searchDirectory = localConfigSearchDirectory,
           fs.fileExists(atPath: configDirectory),
           searchDirectory != dirPath,
           let fallbackWatch = startLocalDirectoryWatchSource(at: searchDirectory, eventHandler: eventHandler) {
            localFallbackDirectoryWatchSource = fallbackWatch.source
            localFallbackDirectoryDescriptor = fallbackWatch.fileDescriptor
        }
    }

    private func startLocalDirectoryWatchSource(
        at dirPath: String,
        eventHandler: @escaping () -> Void
    ) -> (source: DispatchSourceFileSystemObject, fileDescriptor: Int32)? {
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )
        source.setEventHandler(handler: eventHandler)
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        return (source, fd)
    }

    private func handleLocalDirectoryWatchEvent() {
        if let searchDirectory = localConfigSearchDirectory {
            let resolvedPath = resolvedLocalConfigPath(startingFrom: searchDirectory)
            if resolvedPath != localConfigPath {
                localConfigPath = resolvedPath
            }
        }
        guard let configPath = localConfigPath else { return }
        let configDirectory = (configPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: configPath) ||
            FileManager.default.fileExists(atPath: configDirectory) else { return }
        // File or its parent directory appeared — switch to file-level watching.
        stopLocalFileWatcher()
        loadAll()
        startLocalFileWatcher()
    }

    private func scheduleLocalReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let path = self.localConfigPath else { return }
                if FileManager.default.fileExists(atPath: path) {
                    self.loadAll()
                    self.startLocalFileWatcher()
                } else {
                    self.startLocalDirectoryWatcher()
                }
            }
        }
    }

    func stopLocalFileWatcher() {
        if let source = localFileWatchSource {
            source.cancel()
            localFileWatchSource = nil
        }
        stopLocalHookFileWatchers()
        if let source = localFallbackDirectoryWatchSource {
            source.cancel()
            localFallbackDirectoryWatchSource = nil
        }
        localFileDescriptor = -1
        localFallbackDirectoryDescriptor = -1
    }

    // MARK: - File watching (global)

    /// Watches the global config via ``CmuxFileWatch/FileWatcher``, which handles
    /// inode reattachment and nearest-existing-ancestor recovery internally; each
    /// change reloads. Ensures the config directory exists first (the previous
    /// directory-watcher created it).
    func startGlobalWatching() {
        stopGlobalWatching()
        let dirPath = (globalConfigPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dirPath) {
            try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }
        let watcher = FileWatcher(path: globalConfigPath)
        globalWatcher = watcher
        let events = watcher.events
        globalWatchTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                self.loadAll()
            }
        }
    }

    private func stopGlobalWatching() {
        globalWatchTask?.cancel()
        globalWatchTask = nil
        globalWatcher = nil
    }
}

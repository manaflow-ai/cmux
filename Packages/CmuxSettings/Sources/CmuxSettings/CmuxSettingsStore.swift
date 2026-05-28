import Dispatch
import Foundation

public struct CmuxSettingsFileSnapshot: Equatable, Sendable {
    public var url: URL
    public var contents: String

    public init(url: URL, contents: String) {
        self.url = url
        self.contents = contents
    }
}

public enum CmuxSettingsStoreError: Error, Equatable {
    case unreadableData(URL)
}

public actor CmuxSettingsStore {
    public let primaryURL: URL
    public let fallbackURLs: [URL]

    private let fileManager: FileManager

    public init(
        primaryURL: URL = CmuxSettingsCatalog.defaultPrimaryURL(),
        fallbackURLs: [URL] = [CmuxSettingsCatalog.defaultLegacyURL()],
        fileManager: FileManager = .default
    ) {
        self.primaryURL = primaryURL
        self.fallbackURLs = fallbackURLs
        self.fileManager = fileManager
    }

    public func readActiveSnapshot() throws -> CmuxSettingsFileSnapshot {
        let activeURL = ([primaryURL] + fallbackURLs).first { url in
            fileManager.fileExists(atPath: url.path)
        } ?? primaryURL
        return try readSnapshot(at: activeURL)
    }

    public func readPrimarySnapshot() throws -> CmuxSettingsFileSnapshot {
        try readSnapshot(at: primaryURL)
    }

    public func writePrimaryContents(_ contents: String) throws {
        try fileManager.createDirectory(
            at: primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: primaryURL, atomically: true, encoding: .utf8)
    }

    public nonisolated func primaryChanges() -> AsyncStream<CmuxSettingsFileSnapshot> {
        fileChanges(at: primaryURL)
    }

    public nonisolated func fileChanges(at url: URL) -> AsyncStream<CmuxSettingsFileSnapshot> {
        AsyncStream { continuation in
            let watcher = CmuxSettingsFileWatcher(url: url) {
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
                continuation.yield(CmuxSettingsFileSnapshot(url: url, contents: contents))
            }
            continuation.onTermination = { _ in watcher.cancel() }
        }
    }

    private func readSnapshot(at url: URL) throws -> CmuxSettingsFileSnapshot {
        guard fileManager.fileExists(atPath: url.path) else {
            return CmuxSettingsFileSnapshot(url: url, contents: "")
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw CmuxSettingsStoreError.unreadableData(url)
        }
        return CmuxSettingsFileSnapshot(url: url, contents: contents)
    }
}

private final class CmuxSettingsFileWatcher: @unchecked Sendable {
    private let queue: DispatchQueue
    private let source: DispatchSourceFileSystemObject?
    private let fileDescriptor: CInt
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var isCancelled = false

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.queue = DispatchQueue(label: "com.cmux.settings.file-watcher.\(UUID().uuidString)")
        self.onChange = onChange

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            fileDescriptor = -1
            source = nil
            return
        }

        fileDescriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        self.source = source
        source.setEventHandler { [weak self] in
            self?.onChange()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
    }

    deinit {
        cancel()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return }
        isCancelled = true
        source?.cancel()
        if source == nil, fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }
}

import Darwin
import Foundation

extension CMUXCLI {
    struct MainVerticalState: Codable {
        /// The surface ID of the "main" (leader) pane on the left side.
        var mainSurfaceId: String
        /// The surface ID of the bottom-most pane in the right column.
        /// Subsequent teammate splits target this pane with direction "down".
        var lastColumnSurfaceId: String?
    }

    struct TmuxCompatStore: Codable {
        var buffers: [String: String] = [:]
        var hooks: [String: String] = [:]
        /// Tracks main-vertical layout state per workspace, keyed by workspace ID.
        var mainVerticalLayouts: [String: MainVerticalState] = [:]
        /// Tracks the last surface created by split-window per workspace.
        /// Used to seed lastColumnSurfaceId when select-layout main-vertical
        /// is called after the first split.
        var lastSplitSurface: [String: String] = [:]

        /// Custom decoder so older store files missing newer keys
        /// (mainVerticalLayouts, lastSplitSurface) decode gracefully
        /// instead of throwing and resetting the entire store.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            buffers = try container.decodeIfPresent([String: String].self, forKey: .buffers) ?? [:]
            hooks = try container.decodeIfPresent([String: String].self, forKey: .hooks) ?? [:]
            mainVerticalLayouts = try container.decodeIfPresent([String: MainVerticalState].self, forKey: .mainVerticalLayouts) ?? [:]
            lastSplitSurface = try container.decodeIfPresent([String: String].self, forKey: .lastSplitSurface) ?? [:]
        }

        init() {}
    }

    func tmuxCompatStoreURL() -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"]
            ?? NSString(string: "~").expandingTildeInPath
        return URL(fileURLWithPath: homePath)
            .appendingPathComponent(".cmuxterm")
            .appendingPathComponent("tmux-compat-store.json")
    }

    private final class TmuxCompatStoreDirectory {
        let descriptor: Int32
        let storeName: String
        let lockName: String

        init(storeURL: URL, createIfMissing: Bool) throws {
            let parent = storeURL.deletingLastPathComponent()
            if createIfMissing {
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let fd = parent.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard fd >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var metadata = stat()
            guard Darwin.fstat(fd, &metadata) == 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                Darwin.close(fd)
                throw error
            }
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                Darwin.close(fd)
                throw POSIXError(.ENOTDIR)
            }
            guard Darwin.fchmod(fd, mode_t(S_IRUSR | S_IWUSR | S_IXUSR)) == 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                Darwin.close(fd)
                throw error
            }
            descriptor = fd
            storeName = storeURL.lastPathComponent
            lockName = storeURL.lastPathComponent + ".lock"
        }

        deinit {
            Darwin.close(descriptor)
        }

        func open(_ name: String, flags: Int32, mode: mode_t = 0) throws -> Int32 {
            let fd = name.withCString { Darwin.openat(descriptor, $0, flags, mode) }
            guard fd >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return fd
        }

        func rename(_ source: String, to destination: String) throws {
            let result = source.withCString { sourcePointer in
                destination.withCString { destinationPointer in
                    Darwin.renameat(descriptor, sourcePointer, descriptor, destinationPointer)
                }
            }
            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        func unlink(_ name: String) {
            _ = name.withCString { Darwin.unlinkat(descriptor, $0, 0) }
        }
    }

    func loadTmuxCompatStore() throws -> TmuxCompatStore {
        let directory: TmuxCompatStoreDirectory
        do {
            directory = try TmuxCompatStoreDirectory(storeURL: tmuxCompatStoreURL(), createIfMissing: false)
        } catch let error as POSIXError where error.code == .ENOENT {
            return TmuxCompatStore()
        }
        do {
            let data = try readTmuxCompatStoreData(in: directory)
            return try JSONDecoder().decode(TmuxCompatStore.self, from: data)
        } catch let error as POSIXError where error.code == .ENOENT {
            return TmuxCompatStore()
        }
    }

    private func readTmuxCompatStoreData(in directory: TmuxCompatStoreDirectory) throws -> Data {
        let descriptor = try directory.open(directory.storeName, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw POSIXError(.EINVAL)
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, baseAddress, rawBuffer.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    func saveTmuxCompatStore(_ store: TmuxCompatStore) throws {
        try withLockedTmuxCompatStore { current in
            current = store
        }
    }

    private func saveTmuxCompatStore(
        _ store: TmuxCompatStore,
        in directory: TmuxCompatStoreDirectory
    ) throws {
        let data = try JSONEncoder().encode(store)
        let tempName = ".tmux-compat-store-\(UUID().uuidString).tmp"
        let descriptor = try directory.open(
            tempName,
            flags: O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode: mode_t(S_IRUSR | S_IWUSR)
        )
        var isOpen = true
        var didReplace = false
        defer {
            if isOpen {
                Darwin.close(descriptor)
            }
            if !didReplace {
                directory.unlink(tempName)
            }
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard written > 0 else { throw POSIXError(.EIO) }
                offset += written
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.close(descriptor) == 0 else {
            isOpen = false
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        isOpen = false
        try directory.rename(tempName, to: directory.storeName)
        didReplace = true
    }

    /// Serializes cross-process mutations of a tmux compatibility store.
    ///
    /// Each CLI invocation is a separate process, so an in-memory lock cannot
    /// protect the store. The lock file remains stable while the JSON file is
    /// atomically replaced by its writer.
    func withTmuxCompatStoreFileLock<T>(at storeURL: URL, _ body: () throws -> T) throws -> T {
        try withLockedStoreDirectory(at: storeURL) { _ in try body() }
    }

    private func withLockedStoreDirectory<T>(
        at storeURL: URL,
        _ body: (TmuxCompatStoreDirectory) throws -> T
    ) throws -> T {
        let directory = try TmuxCompatStoreDirectory(storeURL: storeURL, createIfMissing: true)
        let lockDescriptor = try directory.open(
            directory.lockName,
            flags: O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode: mode_t(S_IRUSR | S_IWUSR)
        )
        defer { Darwin.close(lockDescriptor) }
        guard Darwin.fchmod(lockDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        while flock(lockDescriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }
        return try body(directory)
    }

    /// Performs one complete tmux compatibility store read-modify-write while
    /// holding the cross-process lock.
    func withLockedTmuxCompatStore<T>(
        _ body: (inout TmuxCompatStore) throws -> T
    ) throws -> T {
        try withLockedStoreDirectory(at: tmuxCompatStoreURL()) { directory in
            var store = try loadTmuxCompatStore(from: directory)
            let result = try body(&store)
            try saveTmuxCompatStore(store, in: directory)
            return result
        }
    }

    private func loadTmuxCompatStore(from directory: TmuxCompatStoreDirectory) throws -> TmuxCompatStore {
        do {
            let data = try readTmuxCompatStoreData(in: directory)
            return try JSONDecoder().decode(TmuxCompatStore.self, from: data)
        } catch let error as POSIXError where error.code == .ENOENT {
            return TmuxCompatStore()
        }
    }

    func withLockedTmuxCompatStoreIfChanged(
        _ body: (inout TmuxCompatStore) throws -> Bool
    ) throws {
        try withLockedStoreDirectory(at: tmuxCompatStoreURL()) { directory in
            var store = try loadTmuxCompatStore(from: directory)
            if try body(&store) {
                try saveTmuxCompatStore(store, in: directory)
            }
        }
    }
}

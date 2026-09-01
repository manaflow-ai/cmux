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

    func loadTmuxCompatStore() throws -> TmuxCompatStore {
        let url = tmuxCompatStoreURL()
        guard let data = try readTmuxCompatStoreData(at: url) else {
            return TmuxCompatStore()
        }
        return try JSONDecoder().decode(TmuxCompatStore.self, from: data)
    }

    private func readTmuxCompatStoreData(at url: URL) throws -> Data? {
        try validateTmuxCompatStoreDirectory(at: url.deletingLastPathComponent())
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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
        let url = tmuxCompatStoreURL()
        let parent = url.deletingLastPathComponent()
        try ensureTmuxCompatStoreDirectory(at: parent)
        let data = try JSONEncoder().encode(store)
        let tempURL = parent.appendingPathComponent(".tmux-compat-store-\(UUID().uuidString).tmp")
        let fileManager = FileManager.default
        guard fileManager.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tempURL.path])
        }
        var didReplace = false
        defer {
            if !didReplace {
                try? fileManager.removeItem(at: tempURL)
            }
        }
        // Keep the replacement owner-only even when the process umask is lax.
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        let renameResult = tempURL.path.withCString { source in
            url.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        didReplace = true
    }

    private func ensureTmuxCompatStoreDirectory(at parent: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validateTmuxCompatStoreDirectory(at: parent)
        // Also tighten an existing directory created by an older CLI.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    }

    private func validateTmuxCompatStoreDirectory(at parent: URL) throws {
        var metadata = stat()
        guard Darwin.lstat(parent.path, &metadata) == 0 else {
            if errno == ENOENT {
                return
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw POSIXError(.ENOTDIR)
        }
    }

    /// Serializes cross-process mutations of a tmux compatibility store.
    ///
    /// Each CLI invocation is a separate process, so an in-memory lock cannot
    /// protect the store. The lock file remains stable while the JSON file is
    /// atomically replaced by its writer.
    func withTmuxCompatStoreFileLock<T>(at storeURL: URL, _ body: () throws -> T) throws -> T {
        let parent = storeURL.deletingLastPathComponent()
        try ensureTmuxCompatStoreDirectory(at: parent)

        let lockURL = URL(fileURLWithPath: storeURL.path + ".lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR {
                continue
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Performs one complete tmux compatibility store read-modify-write while
    /// holding the cross-process lock.
    func withLockedTmuxCompatStore<T>(
        _ body: (inout TmuxCompatStore) throws -> T
    ) throws -> T {
        try withTmuxCompatStoreFileLock(at: tmuxCompatStoreURL()) {
            var store = try loadTmuxCompatStore()
            let result = try body(&store)
            try saveTmuxCompatStore(store)
            return result
        }
    }

    func withLockedTmuxCompatStoreIfChanged(
        _ body: (inout TmuxCompatStore) throws -> Bool
    ) throws {
        try withTmuxCompatStoreFileLock(at: tmuxCompatStoreURL()) {
            var store = try loadTmuxCompatStore()
            if try body(&store) {
                try saveTmuxCompatStore(store)
            }
        }
    }
}

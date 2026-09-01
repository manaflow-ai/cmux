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

    func loadTmuxCompatStore() -> TmuxCompatStore {
        let url = tmuxCompatStoreURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TmuxCompatStore.self, from: data) else {
            return TmuxCompatStore()
        }
        return decoded
    }

    func saveTmuxCompatStore(_ store: TmuxCompatStore) throws {
        let url = tmuxCompatStoreURL()
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder().encode(store)
        try data.write(to: url, options: .atomic)
    }

    /// Serializes cross-process mutations of a tmux compatibility store.
    ///
    /// Each CLI invocation is a separate process, so an in-memory lock cannot
    /// protect the store. The lock file remains stable while the JSON file is
    /// atomically replaced by its writer.
    func withTmuxCompatStoreFileLock<T>(at storeURL: URL, _ body: () throws -> T) throws -> T {
        let parent = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)

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
            var store = loadTmuxCompatStore()
            let result = try body(&store)
            try saveTmuxCompatStore(store)
            return result
        }
    }

    func withLockedTmuxCompatStoreIfChanged(
        _ body: (inout TmuxCompatStore) throws -> Bool
    ) throws {
        try withTmuxCompatStoreFileLock(at: tmuxCompatStoreURL()) {
            var store = loadTmuxCompatStore()
            if try body(&store) {
                try saveTmuxCompatStore(store)
            }
        }
    }
}

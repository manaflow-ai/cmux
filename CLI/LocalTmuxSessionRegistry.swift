import Darwin
import Foundation

/// Durable identity and workspace hints for one local tmux session.
struct LocalTmuxSessionRecord: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var socketPath: String
    var cwd: String
    var workspaceID: String?
    var workspaceTitle: String?
    var surfaceID: String?
    var createdAt: TimeInterval
    var updatedAt: TimeInterval

    init(
        id: UUID = UUID(),
        name: String,
        socketPath: String,
        cwd: String,
        workspaceID: String? = nil,
        workspaceTitle: String? = nil,
        surfaceID: String? = nil,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.name = name
        self.socketPath = socketPath
        self.cwd = cwd
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.surfaceID = surfaceID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

private struct LocalTmuxRegistryFile: Codable {
    var version: Int = 1
    var sessions: [LocalTmuxSessionRecord] = []
}

enum LocalTmuxRegistryError: Error, CustomStringConvertible {
    case insecurePath(String)
    case cannotLock(String)
    case invalidState(String)
    case fileSystem(String)

    var description: String {
        switch self {
        case .insecurePath, .cannotLock, .invalidState, .fileSystem:
            return String(localized: "cli.localTmux.error.stateOperationFailed", defaultValue: "local-tmux state could not be accessed safely")
        }
    }
}

/// File-backed source of truth for opt-in local tmux sessions.
///
/// The registry is deliberately separate from cmux's layout snapshot. Its
/// UUID remains stable when runtime workspace/surface IDs are regenerated, and
/// its 0700/0600 boundary is the authentication boundary for headless clients.
struct LocalTmuxSessionRegistry {
    let rootURL: URL
    let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> LocalTmuxSessionRegistry {
        let root: URL
        if let override = environment["CMUX_LOCAL_TMUX_STATE_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            root = URL(
                fileURLWithPath: NSString(string: override).expandingTildeInPath,
                isDirectory: true
            )
        } else {
            root = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".cmux", isDirectory: true)
                .appendingPathComponent("local-tmux", isDirectory: true)
        }
        return LocalTmuxSessionRegistry(rootURL: root, fileManager: fileManager)
    }

    var sessionsURL: URL {
        rootURL.appendingPathComponent("sessions.json", isDirectory: false)
    }

    var lockURL: URL {
        rootURL.appendingPathComponent("sessions.lock", isDirectory: false)
    }

    /// The one tmux server socket owned by this profile.
    var serverSocketURL: URL {
        rootURL.appendingPathComponent("server.sock", isDirectory: false)
    }

    func load() throws -> [LocalTmuxSessionRecord] {
        try ensureSecureStorage()
        return try withLockedState(write: false) { state in state.sessions }
    }

    func upsert(_ record: LocalTmuxSessionRecord) throws {
        try ensureSecureStorage()
        try withLockedState { state in
            state.sessions.removeAll { $0.id == record.id || $0.name == record.name }
            state.sessions.append(record)
            state.sessions.sort { $0.createdAt < $1.createdAt }
        }
    }

    @discardableResult
    func remove(id: UUID? = nil, name: String? = nil) throws -> [LocalTmuxSessionRecord] {
        try ensureSecureStorage()
        return try withLockedState { state in
            let removed = state.sessions.filter { record in
                (id != nil && record.id == id) || (name != nil && record.name == name)
            }
            state.sessions.removeAll { record in
                (id != nil && record.id == id) || (name != nil && record.name == name)
            }
            return removed
        }
    }

    func remove(where shouldRemove: (LocalTmuxSessionRecord) -> Bool) throws -> [LocalTmuxSessionRecord] {
        try ensureSecureStorage()
        return try withLockedState { state in
            let removed = state.sessions.filter(shouldRemove)
            state.sessions.removeAll(where: shouldRemove)
            return removed
        }
    }

    func ensureSecureStorage() throws {
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: rootURL.path
            )
        } catch {
            let message = String(localized: "cli.localTmux.error.createDirectory", defaultValue: "could not create local-tmux state directory")
            throw LocalTmuxRegistryError.fileSystem("\(message): \(error)")
        }
        try validateSecurePath(rootURL.path, expectedDirectory: true)
        if fileManager.fileExists(atPath: sessionsURL.path) {
            try validateSecurePath(sessionsURL.path, expectedDirectory: false)
        }
        if fileManager.fileExists(atPath: lockURL.path) {
            try validateSecurePath(lockURL.path, expectedDirectory: false)
        }
    }

    /// Verifies tmux did not leave a socket owned by another user or with
    /// group/world access after a crash or an interrupted server upgrade.
    func validateServerSocketIfPresent() throws {
        guard fileManager.fileExists(atPath: serverSocketURL.path) else { return }
        var info = stat()
        guard lstat(serverSocketURL.path, &info) == 0 else {
            throw LocalTmuxRegistryError.insecurePath(serverSocketURL.path)
        }
        let mode = info.st_mode & 0o777
        let isSocket = (info.st_mode & S_IFMT) == S_IFSOCK
        guard info.st_uid == getuid(), mode & 0o077 == 0, isSocket else {
            throw LocalTmuxRegistryError.insecurePath(serverSocketURL.path)
        }
    }

    private func validateSecurePath(_ path: String, expectedDirectory: Bool) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw LocalTmuxRegistryError.insecurePath(path)
        }
        let mode = info.st_mode & 0o777
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        guard info.st_uid == getuid(), mode & 0o077 == 0, isDirectory == expectedDirectory else {
            throw LocalTmuxRegistryError.insecurePath(path)
        }
    }

    private func withLockedState<T>(
        write: Bool = true,
        _ body: (inout LocalTmuxRegistryFile) throws -> T
    ) throws -> T {
        let descriptor: Int32
        if write {
            descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        } else {
            descriptor = open(lockURL.path, O_RDONLY)
            if descriptor < 0, errno == ENOENT {
                var state = try readUnlocked()
                return try body(&state)
            }
        }
        guard descriptor >= 0 else {
            throw LocalTmuxRegistryError.cannotLock(lockURL.path)
        }
        defer { close(descriptor) }
        guard flock(descriptor, write ? LOCK_EX : LOCK_SH) == 0 else {
            throw LocalTmuxRegistryError.cannotLock(lockURL.path)
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        var state = try readUnlocked()
        let result = try body(&state)
        if write { try writeUnlocked(state) }
        return result
    }

    private func readUnlocked() throws -> LocalTmuxRegistryFile {
        guard fileManager.fileExists(atPath: sessionsURL.path) else {
            return LocalTmuxRegistryFile()
        }
        do {
            let data = try Data(contentsOf: sessionsURL)
            let state = try JSONDecoder().decode(LocalTmuxRegistryFile.self, from: data)
            guard state.version == 1 else {
                throw LocalTmuxRegistryError.invalidState(sessionsURL.path)
            }
            return state
        } catch let error as LocalTmuxRegistryError {
            throw error
        } catch {
            throw LocalTmuxRegistryError.invalidState(sessionsURL.path)
        }
    }

    private func writeUnlocked(_ state: LocalTmuxRegistryFile) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            let temporary = rootURL.appendingPathComponent(
                ".sessions.\(UUID().uuidString).tmp",
                isDirectory: false
            )
            defer { try? fileManager.removeItem(at: temporary) }
            guard fileManager.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            ) else {
                let message = String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.error.writeState", defaultValue: "could not write %@"),
                    sessionsURL.path
                )
                throw LocalTmuxRegistryError.fileSystem(message)
            }
            if fileManager.fileExists(atPath: sessionsURL.path) {
                _ = try fileManager.replaceItemAt(sessionsURL, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: sessionsURL)
            }
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: sessionsURL.path
            )
        } catch let error as LocalTmuxRegistryError {
            throw error
        } catch {
            let message = String.localizedStringWithFormat(
                String(localized: "cli.localTmux.error.persistState", defaultValue: "could not persist %@"),
                sessionsURL.path
            )
            throw LocalTmuxRegistryError.fileSystem("\(message): \(error)")
        }
    }
}

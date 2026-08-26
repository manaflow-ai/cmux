import Foundation

/// Loads Claude Code's authoritative task snapshot for one task list.
///
/// Claude task tools mutate individual JSON files. Consumers should load the
/// complete directory after each task-tool event instead of accumulating
/// partial mutations in memory.
public struct ClaudeTaskSnapshotLoader {
    /// Maximum visible entries inspected in one session task directory.
    static let maximumDirectoryEntryCount = 512
    /// Maximum visible entries inspected while resolving a team directory.
    static let maximumTaskRootEntryCount = 512
    /// Maximum bytes read from one task JSON file.
    static let maximumTaskFileByteCount = 64 * 1024
    /// Maximum UTF-8 bytes retained from one task text field.
    static let maximumTaskTextByteCount = 8 * 1024
    /// Maximum aggregate UTF-8 bytes retained in one authoritative snapshot.
    static let maximumSnapshotTextByteCount = 512 * 1024

    /// The directory containing Claude's per-session task directories.
    public let tasksRootURL: URL

    private let fileSystem: any ClaudeTaskFileSystem
    private let operationDeadline: ClaudeTaskOperationDeadline

    /// Creates a loader rooted at a specific Claude tasks directory.
    ///
    /// - Parameters:
    ///   - tasksRootURL: The directory that contains session task directories.
    ///   - fileManager: The filesystem implementation used to enumerate snapshots.
    ///   - deadlineUptime: An optional absolute monotonic deadline for all reads.
    ///   - uptime: The injectable monotonic clock used to enforce the deadline.
    public init(
        tasksRootURL: URL,
        fileManager: any ClaudeTaskFileSystem = FileManager(),
        deadlineUptime: TimeInterval? = nil,
        uptime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.tasksRootURL = tasksRootURL.canonicalClaudeTaskStoreDirectoryURL
        fileSystem = fileManager
        operationDeadline = ClaudeTaskOperationDeadline(
            deadlineUptime: deadlineUptime,
            uptime: uptime
        )
    }

    /// Returns the direct-child directory name Claude derives from a task-list identifier.
    ///
    /// - Parameter taskListID: Claude's raw `CLAUDE_CODE_TASK_LIST_ID` value.
    /// - Returns: The canonical directory name, or `nil` for an empty identifier.
    public func canonicalDirectoryName(forTaskListID taskListID: String) -> String? {
        ClaudeTaskListDirectoryName(taskListID: taskListID)?.rawValue
    }

    /// Reads the authoritative tasks persisted for a configured task-list identifier.
    ///
    /// Claude maps `CLAUDE_CODE_TASK_LIST_ID` to one direct child directory by
    /// replacing every character outside `[a-zA-Z0-9_-]` with `-`. A missing
    /// configured directory returns `nil` without considering session or
    /// neighboring task directories.
    ///
    /// - Parameter taskListID: Claude's non-empty `CLAUDE_CODE_TASK_LIST_ID` value.
    /// - Returns: The configured task-list snapshot, or `nil` when the identifier
    ///   is empty or its direct child directory does not exist.
    /// - Throws: A filesystem or resource-bound error while reading the directory.
    public func loadConfiguredTaskList(taskListID: String) throws -> ClaudeTaskSnapshot? {
        try operationDeadline.check()
        guard !taskListID.isEmpty,
              let directoryName = canonicalDirectoryName(forTaskListID: taskListID),
              let taskListDirectory = try directoryURL(named: directoryName) else {
            return nil
        }
        return try snapshot(in: taskListDirectory)
    }

    /// Reads a task list whose shared identity was configured or proven earlier.
    ///
    /// Unlike ``loadConfiguredTaskList(taskListID:)``, a missing direct child is
    /// returned as an authoritative empty snapshot. Claude removes completed
    /// shared task directories without emitting a later task-tool hook, so a
    /// known identity must remain usable long enough to clear its owned rows.
    ///
    /// - Parameter taskListID: A configured or previously proven shared list ID.
    /// - Returns: The known list snapshot, including an empty snapshot when its
    ///   canonical direct child no longer exists, or `nil` for an empty ID.
    /// - Throws: A filesystem or resource-bound error while reading the directory.
    public func loadKnownTaskList(taskListID: String) throws -> ClaudeTaskSnapshot? {
        try operationDeadline.check()
        guard !taskListID.isEmpty,
              let directoryName = canonicalDirectoryName(forTaskListID: taskListID) else {
            return nil
        }
        guard let taskListDirectory = try directoryURL(named: directoryName) else {
            return ClaudeTaskSnapshot(directoryName: directoryName, todos: [])
        }
        do {
            let loadedSnapshot = try snapshot(in: taskListDirectory)
            try operationDeadline.check()
            guard try directoryURL(named: directoryName) != nil else {
                return ClaudeTaskSnapshot(directoryName: directoryName, todos: [])
            }
            return loadedSnapshot
        } catch ClaudeTaskSnapshotLoaderError.cannotEnumerateSessionDirectory {
            try operationDeadline.check()
            guard try directoryURL(named: directoryName) == nil else {
                throw ClaudeTaskSnapshotLoaderError.cannotEnumerateSessionDirectory
            }
            return ClaudeTaskSnapshot(directoryName: directoryName, todos: [])
        }
    }

    /// Reads only one previously proven direct-child binding.
    ///
    /// A mismatched current task identity fails closed instead of scanning a
    /// neighboring list. Callers may separately choose the exact-identity
    /// compatibility scan only when they have no durable binding.
    ///
    /// - Parameters:
    ///   - directoryName: The direct-child name proven by an earlier hook.
    ///   - taskIdentity: The exact current task identity, when available.
    /// - Returns: The bound snapshot, or `nil` when the directory is absent or
    ///   does not contain the current task identity.
    /// - Throws: A filesystem or resource-bound error while reading the directory.
    public func loadBoundTaskList(
        directoryName: String,
        taskIdentity: ClaudeTaskIdentity? = nil
    ) throws -> ClaudeTaskSnapshot? {
        try operationDeadline.check()
        guard let directory = try directoryURL(named: directoryName) else { return nil }
        if let taskIdentity {
            guard try taskFile(
                in: directory,
                matches: taskIdentity,
                decoder: JSONDecoder()
            ) else { return nil }
        }
        return try snapshot(in: directory)
    }

    /// Reads only the deterministic task directory candidates for one session.
    ///
    /// This method never scans neighboring task directories. Callers use it
    /// after authoritative automatic-team resolution, because task IDs are
    /// list-local and a stale personal directory cannot disprove team
    /// membership. When an exact hook identity is available, the direct
    /// directory must contain the matching task record.
    ///
    /// - Parameters:
    ///   - sessionID: Claude's hook `session_id` value.
    ///   - taskIdentity: The exact task identity reported by the current hook,
    ///     when available.
    /// - Returns: The direct session snapshot, or `nil` when no deterministic
    ///   candidate contains the current task identity.
    /// - Throws: A filesystem or resource-bound error while reading the directory.
    public func loadDirectSessionTaskList(
        sessionID: String,
        taskIdentity: ClaudeTaskIdentity? = nil
    ) throws -> ClaudeTaskSnapshot? {
        try operationDeadline.check()
        guard let sessionDirectory = try sessionDirectoryURL(sessionID: sessionID) else {
            return nil
        }
        if let taskIdentity {
            guard try taskFile(
                in: sessionDirectory,
                matches: taskIdentity,
                decoder: JSONDecoder()
            ) else {
                return nil
            }
        }
        return try snapshot(in: sessionDirectory)
    }

    /// Resolves and reads the authoritative tasks currently persisted for a session.
    ///
    /// Both `<tasks>/<session-id>` and the older
    /// `<tasks>/session-<session-id>` directory layouts are supported. Team
    /// task directories whose names are unrelated to the hook session are
    /// accepted only when a task id and subject match exactly. A previously
    /// proven binding is reused when the current hook confirms it or carries
    /// no identity, and permits an empty directory to be returned as an
    /// authoritative deletion snapshot.
    ///
    /// Malformed task files and tasks marked `deleted` are omitted.
    ///
    /// - Parameters:
    ///   - sessionID: Claude's hook `session_id` value.
    ///   - boundDirectoryName: A task-directory name previously proven for
    ///     this hook session.
    ///   - taskIdentity: The exact task identity reported by the current hook,
    ///     when available.
    /// - Returns: The resolved snapshot in stable task-id order, or `nil` when
    ///   no directory can be proven uniquely. A non-`nil` snapshot may contain
    ///   an empty `todos` array.
    /// - Throws: A filesystem or resource-bound error while resolving or
    ///   enumerating a task directory.
    public func load(
        sessionID: String,
        boundDirectoryName: String? = nil,
        taskIdentity: ClaudeTaskIdentity? = nil
    ) throws -> ClaudeTaskSnapshot? {
        try operationDeadline.check()
        let decoder = JSONDecoder()
        if let boundDirectoryName,
           let boundDirectory = try directoryURL(named: boundDirectoryName) {
            if let taskIdentity {
                if try taskFile(in: boundDirectory, matches: taskIdentity, decoder: decoder) {
                    return try snapshot(in: boundDirectory)
                }
            } else {
                return try snapshot(in: boundDirectory)
            }
        }

        // A deterministic session directory is authoritative even when its
        // current task file is mid-write or no longer matches the hook
        // identity. Never fall through to a neighboring list in that case:
        // task IDs are only unique within one directory.
        if let sessionDirectory = try sessionDirectoryURL(sessionID: sessionID) {
            if let taskIdentity {
                guard try taskFile(
                    in: sessionDirectory,
                    matches: taskIdentity,
                    decoder: decoder
                ) else { return nil }
            }
            return try snapshot(in: sessionDirectory)
        }

        if let taskIdentity,
           let matchedDirectory = try uniquelyMatchingDirectory(
               for: taskIdentity,
               decoder: decoder
           ) {
            return try snapshot(in: matchedDirectory)
        }

        return nil
    }

    private func snapshot(in sessionDirectory: URL) throws -> ClaudeTaskSnapshot {
        try operationDeadline.check()
        var enumerationError: Error?
        let candidateEnumerator = fileSystem.enumerator(
            at: sessionDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                if error.isClaudeTaskFilesystemItemMissing {
                    return true
                }
                enumerationError = error
                return false
            }
        )
        try operationDeadline.check()
        guard let enumerator = candidateEnumerator else {
            throw ClaudeTaskSnapshotLoaderError.cannotEnumerateSessionDirectory
        }
        let decoder = JSONDecoder()
        var todos: [WorkstreamTaskTodo] = []
        var entryCount = 0
        var snapshotTextByteCount = 0
        while let fileURL = enumerator.nextObject() as? URL {
            try operationDeadline.check()
            entryCount += 1
            guard entryCount <= Self.maximumDirectoryEntryCount else {
                throw ClaudeTaskSnapshotLoaderError.tooManyDirectoryEntries(
                    limit: Self.maximumDirectoryEntryCount
                )
            }
            guard fileURL.pathExtension.lowercased() == "json" else { continue }
            let values: URLResourceValues
            do {
                values = try fileSystem.resourceValues(
                    for: fileURL,
                    keys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
            } catch {
                guard error.isClaudeTaskFilesystemItemMissing else { throw error }
                continue
            }
            try operationDeadline.check()
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let data: Data
            do {
                data = try boundedTaskData(
                    at: fileURL,
                    maximumByteCount: Self.maximumTaskFileByteCount
                )
            } catch {
                guard error.isClaudeTaskFilesystemItemMissing else { throw error }
                continue
            }
            try operationDeadline.check()
            guard let record = try? decoder.decode(ClaudeTaskRecord.self, from: data),
                  let taskID = validPathComponent(record.id),
                  taskID == record.id,
                  fileURL.deletingPathExtension().lastPathComponent == taskID,
                  let state = record.canonicalState else { continue }
            try validateTaskText(record.subject, field: "subject", fileURL: fileURL)
            if let activeForm = record.activeForm {
                try validateTaskText(activeForm, field: "activeForm", fileURL: fileURL)
            }
            guard let content = nonEmptyTaskText(record.subject) else { continue }
            let activeForm = nonEmptyTaskText(record.activeForm)
            let taskTextByteCount = content.utf8.count + (activeForm?.utf8.count ?? 0)
            guard taskTextByteCount <= Self.maximumSnapshotTextByteCount - snapshotTextByteCount else {
                throw ClaudeTaskSnapshotLoaderError.snapshotTextTooLarge(
                    limit: Self.maximumSnapshotTextByteCount
                )
            }
            snapshotTextByteCount += taskTextByteCount
            todos.append(WorkstreamTaskTodo(
                id: taskID,
                content: content,
                activeForm: activeForm,
                state: state
            ))
        }
        try operationDeadline.check()
        if let enumerationError { throw enumerationError }
        let sortedTodos = todos.sorted(by: taskSort)
        try operationDeadline.check()
        return ClaudeTaskSnapshot(
            directoryName: sessionDirectory.lastPathComponent,
            todos: sortedTodos
        )
    }

    private func sessionDirectoryURL(sessionID: String) throws -> URL? {
        try operationDeadline.check()
        guard let trimmed = validPathComponent(sessionID) else { return nil }
        let bareID = trimmed.hasPrefix("session-")
            ? String(trimmed.dropFirst("session-".count))
            : trimmed
        let names = [trimmed, bareID, "session-\(bareID)"]
        var seen = Set<String>()
        for name in names where !name.isEmpty && seen.insert(name).inserted {
            try operationDeadline.check()
            if let candidate = try directoryURL(named: name) {
                return candidate
            }
        }
        return nil
    }

    private func uniquelyMatchingDirectory(
        for identity: ClaudeTaskIdentity,
        decoder: JSONDecoder
    ) throws -> URL? {
        try operationDeadline.check()
        guard validPathComponent(identity.id) == identity.id,
              !identity.subject.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        let rootExists = fileSystem.fileExists(
            atPath: tasksRootURL.path,
            isDirectory: &isDirectory
        )
        try operationDeadline.check()
        guard rootExists,
              isDirectory.boolValue else { return nil }

        var enumerationError: Error?
        let candidateEnumerator = fileSystem.enumerator(
            at: tasksRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                if error.isClaudeTaskFilesystemItemMissing {
                    return true
                }
                enumerationError = error
                return false
            }
        )
        try operationDeadline.check()
        guard let enumerator = candidateEnumerator else {
            throw ClaudeTaskSnapshotLoaderError.cannotEnumerateTasksRoot
        }

        var entryCount = 0
        var match: URL?
        while let candidate = enumerator.nextObject() as? URL {
            try operationDeadline.check()
            entryCount += 1
            guard entryCount <= Self.maximumTaskRootEntryCount else {
                throw ClaudeTaskSnapshotLoaderError.tooManyTaskRootEntries(
                    limit: Self.maximumTaskRootEntryCount
                )
            }
            let values: URLResourceValues
            do {
                values = try fileSystem.resourceValues(
                    for: candidate,
                    keys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
            } catch {
                guard error.isClaudeTaskFilesystemItemMissing else { throw error }
                continue
            }
            try operationDeadline.check()
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  try taskFile(in: candidate, matches: identity, decoder: decoder) else { continue }
            guard match == nil else { return nil }
            match = candidate
        }
        try operationDeadline.check()
        if let enumerationError { throw enumerationError }
        return match
    }

    private func taskFile(
        in directory: URL,
        matches identity: ClaudeTaskIdentity,
        decoder: JSONDecoder
    ) throws -> Bool {
        try operationDeadline.check()
        guard let taskID = validPathComponent(identity.id), taskID == identity.id else { return false }
        let fileURL = directory.appendingPathComponent("\(taskID).json", isDirectory: false)
        let values: URLResourceValues
        do {
            values = try fileSystem.resourceValues(
                for: fileURL,
                keys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            guard error.isClaudeTaskFilesystemItemMissing else { throw error }
            return false
        }
        try operationDeadline.check()
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        let data: Data
        do {
            data = try boundedTaskData(
                at: fileURL,
                maximumByteCount: Self.maximumTaskFileByteCount
            )
        } catch {
            guard error.isClaudeTaskFilesystemItemMissing else { throw error }
            return false
        }
        try operationDeadline.check()
        guard let record = try? decoder.decode(ClaudeTaskRecord.self, from: data) else { return false }
        guard record.id == identity.id,
              record.subject == identity.subject,
              record.canonicalState != nil else { return false }
        try validateTaskText(record.subject, field: "subject", fileURL: fileURL)
        return true
    }

    private func directoryURL(named name: String) throws -> URL? {
        try operationDeadline.check()
        guard let name = validPathComponent(name) else { return nil }
        let candidate = tasksRootURL.appendingPathComponent(name, isDirectory: true)
        let values: URLResourceValues
        do {
            values = try fileSystem.resourceValues(
                for: candidate,
                keys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            guard error.isClaudeTaskFilesystemItemMissing else { throw error }
            return nil
        }
        try operationDeadline.check()
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ClaudeTaskSnapshotLoaderError.invalidTaskDirectory(
                directoryName: name
            )
        }
        return candidate
    }

    private func validPathComponent(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\0") else {
            return nil
        }
        return trimmed
    }

    private func nonEmptyTaskText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func validateTaskText(
        _ value: String,
        field: String,
        fileURL: URL
    ) throws {
        guard value.utf8.count <= Self.maximumTaskTextByteCount else {
            throw ClaudeTaskSnapshotLoaderError.taskTextTooLarge(
                fileName: fileURL.lastPathComponent,
                field: field,
                limit: Self.maximumTaskTextByteCount
            )
        }
    }

    private func taskSort(_ lhs: WorkstreamTaskTodo, _ rhs: WorkstreamTaskTodo) -> Bool {
        if let leftNumber = Int(lhs.id), let rightNumber = Int(rhs.id), leftNumber != rightNumber {
            return leftNumber < rightNumber
        }
        return lhs.id < rhs.id
    }

    private func boundedTaskData(at fileURL: URL, maximumByteCount: Int) throws -> Data {
        try operationDeadline.check()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumByteCount + 1) ?? Data()
        try operationDeadline.check()
        guard data.count <= maximumByteCount else {
            throw ClaudeTaskSnapshotLoaderError.taskFileTooLarge(
                fileName: fileURL.lastPathComponent,
                limit: maximumByteCount
            )
        }
        return data
    }
}

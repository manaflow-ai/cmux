import Foundation

/// Loads Claude Code's authoritative task snapshot for one session.
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

    /// The directory containing Claude's per-session task directories.
    public let tasksRootURL: URL

    private let fileManager: FileManager

    /// Creates a loader rooted at a specific Claude tasks directory.
    ///
    /// - Parameters:
    ///   - tasksRootURL: The directory that contains session task directories.
    ///   - fileManager: The filesystem implementation used to read snapshots.
    public init(tasksRootURL: URL, fileManager: FileManager = .default) {
        self.tasksRootURL = tasksRootURL
        self.fileManager = fileManager
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
        let decoder = JSONDecoder()
        if let boundDirectoryName,
           let boundDirectory = directoryURL(named: boundDirectoryName) {
            if let taskIdentity {
                if taskFile(in: boundDirectory, matches: taskIdentity, decoder: decoder) {
                    return try snapshot(in: boundDirectory)
                }
            } else {
                return try snapshot(in: boundDirectory)
            }
        }

        if let taskIdentity,
           let sessionDirectory = sessionDirectoryURL(sessionID: sessionID),
           taskFile(in: sessionDirectory, matches: taskIdentity, decoder: decoder) {
            return try snapshot(in: sessionDirectory)
        }

        if let taskIdentity,
           let matchedDirectory = try uniquelyMatchingDirectory(
               for: taskIdentity,
               decoder: decoder
           ) {
            return try snapshot(in: matchedDirectory)
        }

        guard taskIdentity == nil,
              let sessionDirectory = sessionDirectoryURL(sessionID: sessionID) else {
            return nil
        }
        return try snapshot(in: sessionDirectory)
    }

    private func snapshot(in sessionDirectory: URL) throws -> ClaudeTaskSnapshot {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: sessionDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ClaudeTaskSnapshotLoaderError.cannotEnumerateSessionDirectory
        }
        let decoder = JSONDecoder()
        var todos: [WorkstreamTaskTodo] = []
        var entryCount = 0
        while let fileURL = enumerator.nextObject() as? URL {
            entryCount += 1
            guard entryCount <= Self.maximumDirectoryEntryCount else {
                throw ClaudeTaskSnapshotLoaderError.tooManyDirectoryEntries(
                    limit: Self.maximumDirectoryEntryCount
                )
            }
            guard fileURL.pathExtension.lowercased() == "json" else { continue }
            let values = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let data = try boundedTaskData(
                at: fileURL,
                maximumByteCount: Self.maximumTaskFileByteCount
            )
            guard let record = try? decoder.decode(ClaudeTaskRecord.self, from: data),
                  let state = record.canonicalState,
                  let content = nonEmptyTaskText(record.subject) else { continue }
            todos.append(WorkstreamTaskTodo(
                id: record.id,
                content: content,
                activeForm: nonEmptyTaskText(record.activeForm),
                state: state
            ))
        }
        if let enumerationError { throw enumerationError }
        return ClaudeTaskSnapshot(
            directoryName: sessionDirectory.lastPathComponent,
            todos: todos.sorted(by: taskSort)
        )
    }

    private func sessionDirectoryURL(sessionID: String) -> URL? {
        guard let trimmed = validPathComponent(sessionID) else { return nil }
        let bareID = trimmed.hasPrefix("session-")
            ? String(trimmed.dropFirst("session-".count))
            : trimmed
        let names = [trimmed, bareID, "session-\(bareID)"]
        var seen = Set<String>()
        for name in names where !name.isEmpty && seen.insert(name).inserted {
            if let candidate = directoryURL(named: name) {
                return candidate
            }
        }
        return nil
    }

    private func uniquelyMatchingDirectory(
        for identity: ClaudeTaskIdentity,
        decoder: JSONDecoder
    ) throws -> URL? {
        guard validPathComponent(identity.id) == identity.id,
              !identity.subject.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: tasksRootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: tasksRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ClaudeTaskSnapshotLoaderError.cannotEnumerateTasksRoot
        }

        var entryCount = 0
        var match: URL?
        while let candidate = enumerator.nextObject() as? URL {
            entryCount += 1
            guard entryCount <= Self.maximumTaskRootEntryCount else {
                throw ClaudeTaskSnapshotLoaderError.tooManyTaskRootEntries(
                    limit: Self.maximumTaskRootEntryCount
                )
            }
            let values = try candidate.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  taskFile(in: candidate, matches: identity, decoder: decoder) else { continue }
            guard match == nil else { return nil }
            match = candidate
        }
        if let enumerationError { throw enumerationError }
        return match
    }

    private func taskFile(
        in directory: URL,
        matches identity: ClaudeTaskIdentity,
        decoder: JSONDecoder
    ) -> Bool {
        guard let taskID = validPathComponent(identity.id), taskID == identity.id else { return false }
        let fileURL = directory.appendingPathComponent("\(taskID).json", isDirectory: false)
        guard let values = try? fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true,
              let data = try? boundedTaskData(
                  at: fileURL,
                  maximumByteCount: Self.maximumTaskFileByteCount
              ),
              let record = try? decoder.decode(ClaudeTaskRecord.self, from: data) else {
            return false
        }
        return record.id == identity.id && record.subject == identity.subject
    }

    private func directoryURL(named name: String) -> URL? {
        guard let name = validPathComponent(name) else { return nil }
        let candidate = tasksRootURL.appendingPathComponent(name, isDirectory: true)
        guard let values = try? candidate.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ), values.isDirectory == true, values.isSymbolicLink != true else {
            return nil
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

    private func taskSort(_ lhs: WorkstreamTaskTodo, _ rhs: WorkstreamTaskTodo) -> Bool {
        if let leftNumber = Int(lhs.id), let rightNumber = Int(rhs.id), leftNumber != rightNumber {
            return leftNumber < rightNumber
        }
        return lhs.id < rhs.id
    }

    private func boundedTaskData(at fileURL: URL, maximumByteCount: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumByteCount + 1) ?? Data()
        guard data.count <= maximumByteCount else {
            throw ClaudeTaskSnapshotLoaderError.taskFileTooLarge(
                fileName: fileURL.lastPathComponent,
                limit: maximumByteCount
            )
        }
        return data
    }
}

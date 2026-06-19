import Foundation

/// Errors surfaced by ``KanbanBoardRepository``.
enum KanbanBoardRepositoryError: Error, Equatable {
    /// The board file on disk exists but could not be decoded. The repository
    /// refuses to overwrite it so the user's data is not silently destroyed.
    case corruptedBoardFile(workspaceId: UUID)
}

/// Persists one ``KanbanBoard`` per workspace as JSON under the cmux runtime
/// state directory.
///
/// The repository is an `actor`: all reads and writes are `async` and
/// serialized through actor isolation, with no locks. Boards live under
/// `<baseDirectory>/<workspaceId>.json` and per-card logs under
/// `<baseDirectory>/logs/`. The base directory and `FileManager` are injected
/// so the type is testable against a temp directory with no global state.
///
/// Writes are atomic (temp + rename), so a concurrent reader always sees either
/// the whole old or whole new file. A present-but-undecodable board file makes
/// ``load(workspaceId:now:)`` throw ``KanbanBoardRepositoryError/corruptedBoardFile(workspaceId:)``
/// rather than returning an empty board, so a transient parse failure never
/// clobbers real data on the next save.
///
/// ```swift
/// let home = FileManager.default.homeDirectoryForCurrentUser
/// let base = CmuxStateDirectory.url(homeDirectory: home)
///     .appendingPathComponent("kanban", isDirectory: true)
/// let repo = KanbanBoardRepository(baseDirectory: base)
/// var board = try await repo.load(workspaceId: workspaceId, now: Date())
/// board = board.upserting(KanbanCard(title: "Fix bug", createdAt: now, updatedAt: now), now: now)
/// try await repo.save(board)
/// ```
actor KanbanBoardRepository {
    /// Directory holding the per-workspace board JSON files.
    let baseDirectory: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a repository rooted at `baseDirectory`.
    ///
    /// - Parameters:
    ///   - baseDirectory: Directory under which `<workspaceId>.json` board files
    ///     and the `logs/` subdirectory live. Created lazily on first save.
    ///   - fileManager: Filesystem accessor; injected for testing.
    init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// The on-disk location of a workspace's board file.
    func boardURL(workspaceId: UUID) -> URL {
        baseDirectory.appendingPathComponent("\(workspaceId.uuidString).json", isDirectory: false)
    }

    /// The directory where per-card log files are written.
    var logsDirectory: URL {
        baseDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// The append-only log file for a card.
    func logURL(cardId: UUID) -> URL {
        logsDirectory.appendingPathComponent("\(cardId.uuidString).log", isDirectory: false)
    }

    /// Loads the board for `workspaceId`, returning a fresh empty board when no
    /// file exists yet.
    ///
    /// - Throws: ``KanbanBoardRepositoryError/corruptedBoardFile(workspaceId:)``
    ///   when the file exists but cannot be decoded.
    func load(workspaceId: UUID, now: Date) throws -> KanbanBoard {
        let url = boardURL(workspaceId: workspaceId)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return KanbanBoard.empty(workspaceId: workspaceId, now: now)
        }
        if data.isEmpty {
            return KanbanBoard.empty(workspaceId: workspaceId, now: now)
        }
        do {
            return try decoder.decode(KanbanBoard.self, from: data)
        } catch {
            throw KanbanBoardRepositoryError.corruptedBoardFile(workspaceId: workspaceId)
        }
    }

    /// Atomically writes `board` to its workspace file, creating the base
    /// directory if needed.
    ///
    /// - Throws: Errors from `FileManager` or `JSONEncoder`.
    func save(_ board: KanbanBoard) throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(board)
        try data.write(to: boardURL(workspaceId: board.workspaceId), options: [.atomic])
    }

    /// Appends `text` to a card's log file, creating the `logs/` directory and
    /// the file on first write.
    ///
    /// - Throws: Errors from `FileManager` writing the file.
    func appendLog(cardId: UUID, text: String) throws {
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let url = logURL(cardId: cardId)
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: [.atomic])
        }
    }
}

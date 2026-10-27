#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The on-disk store of voice notes not yet delivered to the Chief.
///
/// Each note is two files in ``directory``: `<id>.json` (the ``VoiceNote``
/// record) and `<id>.m4a` (its audio, written by the recorder straight into
/// ``audioURL(for:)``). Because the recorder writes into the outbox, a crash or
/// kill mid-call still leaves the audio on disk. A new instance over the same
/// directory sees every saved note, so the outbox survives relaunches.
///
/// ```swift
/// let outbox = VoiceNoteOutbox(directory: appSupport.appendingPathComponent("ChiefVoiceNotes"))
/// try await outbox.save(note)
/// for note in await outbox.pending() { ... }
/// ```
///
/// Tests pass a fresh temporary directory.
public actor VoiceNoteOutbox {
    /// The directory holding `<id>.json` records and `<id>.m4a` audio.
    public nonisolated let directory: URL

    /// Creates an outbox over `directory`; the directory is created on first save.
    /// - Parameter directory: Where notes live; the app passes a folder in Application Support.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Creates an outbox for one authenticated account below a shared root.
    ///
    /// - Parameters:
    ///   - rootDirectory: The parent folder for every account's pending notes.
    ///   - accountID: The authenticated account that owns this outbox.
    public init(rootDirectory: URL, accountID: String) {
        Self.discardLegacyUnscopedNotes(in: rootDirectory)
        let digest = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = rootDirectory.appendingPathComponent("account-\(digest)", isDirectory: true)
    }

    /// Deletes notes written before outboxes recorded their owning account.
    ///
    /// Those direct children cannot be assigned safely after an account switch;
    /// account-scoped subdirectories are preserved.
    /// - Parameter rootDirectory: The former shared outbox and current account-folder root.
    public nonisolated static func discardLegacyUnscopedNotes(in rootDirectory: URL) {
        let files = FileManager()
        let legacy = (try? files.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        for file in legacy where file.pathExtension == "json" || file.pathExtension == "m4a" {
            try? files.removeItem(at: file)
        }
    }

    /// Where the audio of note `id` is written.
    /// - Parameter id: The note id.
    /// - Returns: `<directory>/<id>.m4a`.
    public nonisolated func audioURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).m4a")
    }

    private nonisolated func recordURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Creates ``directory`` when missing (the recorder writes into it before the first save).
    /// - Throws: When the directory cannot be created.
    public func prepareDirectory() throws {
        try FileManager().createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Saves or replaces the record of `note` (atomically).
    /// - Parameter note: The note to store.
    /// - Throws: When the directory or file cannot be written.
    public func save(_ note: VoiceNote) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(note).write(to: recordURL(for: note.id), options: .atomic)
    }

    /// Every saved note, oldest first. Unreadable records are skipped.
    public func pending() -> [VoiceNote] {
        let files = (try? FileManager().contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(VoiceNote.self, from: $0) } }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// Removes note `id`: its record and its audio.
    /// - Parameter id: The note id.
    public func remove(_ id: UUID) {
        let files = FileManager()
        try? files.removeItem(at: recordURL(for: id))
        try? files.removeItem(at: audioURL(for: id))
    }
}

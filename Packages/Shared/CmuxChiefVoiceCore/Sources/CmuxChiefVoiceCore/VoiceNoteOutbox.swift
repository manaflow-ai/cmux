import Foundation

/// The on-disk store of voice notes not yet delivered to the Chief.
public actor VoiceNoteOutbox {
    /// The directory holding `<id>.json` records and `<id>.m4a` audio.
    public nonisolated let directory: URL

    /// Creates an outbox over `directory`.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Where the audio of note `id` is written.
    public nonisolated func audioURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).m4a")
    }

    /// Saves or replaces the record of `note`.
    public func save(_ note: VoiceNote) throws {}

    /// Every saved note, oldest first.
    public func pending() -> [VoiceNote] { [] }

    /// Removes note `id` and its audio.
    public func remove(_ id: UUID) {}
}

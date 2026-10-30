import Foundation
import CmuxNextCompat

/// A state file this run cannot read, set aside beside itself so whatever it held can still be
/// recovered, never replaced by a fresh write (``AgentUnsentDrafts``, ``AgentPanePromptJournal``).
nonisolated enum UnreadableStateFile {
    /// Times a taken name gets a fresh id before the move gives up.
    static let attempts = 4

    /// Moves `file` to `<name>.unreadable-<seconds>-<id>.<ext>` beside it and returns where it went.
    /// The id makes each name unique, so two set-asides in one second never meet; a name that is
    /// taken anyway gets a fresh id. Throws when the file could not be moved: the caller then must
    /// not write over it.
    static func setAside(
        _ file: URL,
        now: Date = Date(),
        id: () -> String = { String(UUID().uuidString.prefix(8)).lowercased() }
    ) throws -> URL {
        var failure: (any Error)?
        for _ in 0..<attempts {
            let aside = file.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(now.timeIntervalSince1970))-\(id())")
                .appendingPathExtension(file.pathExtension)
            // concurrency-allow: one rename, only when a state file could not be read
            if FileManager.checked.fileExists(atPath: aside.path) { continue }
            do {
                // concurrency-allow: one rename, only when a state file could not be read
                try FileManager.checked.moveItem(at: file, to: aside)
                return aside
            } catch CocoaError.fileWriteFileExists {
                // Taken between the check and the move: another id.
                continue
            } catch {
                failure = error
                break
            }
        }
        throw failure ?? CocoaError(.fileWriteFileExists)
    }
}

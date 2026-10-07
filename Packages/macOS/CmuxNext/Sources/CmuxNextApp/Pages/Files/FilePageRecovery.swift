import CmuxNextDesign
import Foundation

/// Recovered drafts that belong to the file pages: local files only (a draft never writes a remote
/// file into a local one).
nonisolated enum FilePageRecovery {
    static func document(of draft: RecoveryDraft) -> URL? {
        guard let parts = QuitParticipantID.parse(draft.id), parts.host == QuitParticipantID.localHost,
              draft.host == QuitParticipantID.localHost, draft.filePath == parts.path else { return nil }
        return URL(fileURLWithPath: parts.path)
    }

    /// What a recovered draft opens as: its file, its text, and whether the file differs from the
    /// draft's base (or the draft has no base, or the file is gone). The restore handler gets no
    /// "changed on disk" flag (R96 v2); this reads the file and never writes it.
    struct Restore: Equatable {
        let url: URL
        let text: String
        let conflict: Bool
    }

    @concurrent static func restore(_ draft: RecoveryDraft) async -> Restore? {
        guard let url = document(of: draft) else { return nil }
        let current = (try? Data(contentsOf: url)).map(FileDocument.hash) // concurrency-allow: @concurrent, off the main actor
        let conflict = current == nil || draft.base?.contentHash == nil || current != draft.base?.contentHash
        return Restore(url: url, text: String(decoding: draft.contents, as: UTF8.self), conflict: conflict)
    }
}

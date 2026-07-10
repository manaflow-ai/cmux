import Observation
import Foundation

/// Workspace-scoped pool of saved-but-unsent diff review comments.
///
/// Every terminal TextBox in the workspace shows one "[N comments]" chip
/// while the pool is non-empty; whichever TextBox submits first consumes the
/// whole pool (its submission gets the formatted comments appended) and the
/// chip clears everywhere. Diff viewer pages repopulate the pool through the
/// comments bridge on load and on every save/delete.
@MainActor
@Observable
final class DiffCommentSubmissionPool {
    static let shared = DiffCommentSubmissionPool()

    struct Entry: Equatable {
        let commentId: UUID
        let repoRoot: String
        let submissionText: String
    }

    private(set) var entriesByWorkspace: [UUID: [Entry]] = [:]

    func setPending(_ entry: Entry, workspaceId: UUID) {
        var entries = entriesByWorkspace[workspaceId] ?? []
        if let index = entries.firstIndex(where: { $0.commentId == entry.commentId }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        entriesByWorkspace[workspaceId] = entries
    }

    func removePending(commentId: UUID) {
        for (workspaceId, entries) in entriesByWorkspace {
            let remaining = entries.filter { $0.commentId != commentId }
            if remaining.count != entries.count {
                entriesByWorkspace[workspaceId] = remaining.isEmpty ? nil : remaining
            }
        }
    }

    func pendingCount(workspaceId: UUID?) -> Int {
        guard let workspaceId else { return 0 }
        return entriesByWorkspace[workspaceId]?.count ?? 0
    }

    /// Claims every pending comment for the workspace; the caller appends the
    /// entries' submission text to its outgoing submission and either marks
    /// them consumed in the store or restores them on a failed submit.
    func consumeAll(workspaceId: UUID) -> [Entry] {
        guard let entries = entriesByWorkspace[workspaceId], !entries.isEmpty else { return [] }
        entriesByWorkspace[workspaceId] = nil
        return entries
    }

    /// Puts entries claimed by `consumeAll` back (failed submit rollback).
    func restorePending(_ entries: [Entry], workspaceId: UUID) {
        for entry in entries {
            setPending(entry, workspaceId: workspaceId)
        }
    }
}

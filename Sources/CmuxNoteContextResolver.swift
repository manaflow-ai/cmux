import Foundation

/// Pure resolution of a caller's contextual note(s). Resolution key is
/// "this surface, then workspace": a note linked to `surfaceTarget` wins over
/// one linked only to `workspaceTarget`; ties break on `updatedAt` (newest).
enum CmuxNoteContextResolver {
    static func resolve(
        notes: [CmuxNoteRecord],
        surfaceTarget: CmuxNoteAttachmentTarget?,
        workspaceTarget: CmuxNoteAttachmentTarget?
    ) -> CmuxNoteContextResolution {
        var linkByNoteId: [String: CmuxNoteContextLink] = [:]
        for note in notes {
            if let surfaceTarget, note.attachments.contains(where: { $0.matches(surfaceTarget) }) {
                linkByNoteId[note.id] = .surface
            } else if let workspaceTarget, note.attachments.contains(where: { $0.matches(workspaceTarget) }) {
                linkByNoteId[note.id] = .workspace
            }
        }

        func rank(_ note: CmuxNoteRecord) -> Int {
            switch linkByNoteId[note.id] {
            case .surface: return 0
            case .workspace: return 1
            case nil: return 2
            }
        }

        let ordered = notes.sorted { lhs, rhs in
            let lhsRank = rank(lhs)
            let rhsRank = rank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.slug < rhs.slug
        }

        let resolved = ordered.first { linkByNoteId[$0.id] == .surface }
            ?? ordered.first { linkByNoteId[$0.id] == .workspace }

        return CmuxNoteContextResolution(
            orderedNotes: ordered,
            linkByNoteId: linkByNoteId,
            resolvedNoteId: resolved?.id
        )
    }
}

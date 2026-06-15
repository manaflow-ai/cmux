import Foundation

// MARK: - cmux note index models

struct CmuxNoteAttachment: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case workspace
        case surface
    }

    var kind: Kind
    var workspaceAnchorId: String
    var surfaceAnchorId: String?
    var surfaceKind: String?
    var createdAt: TimeInterval

    func matches(_ target: CmuxNoteAttachmentTarget) -> Bool {
        switch target {
        case .workspace(let workspaceAnchorId):
            return kind == .workspace && self.workspaceAnchorId == workspaceAnchorId
        case .surface(let workspaceAnchorId, let surfaceAnchorId, _):
            return kind == .surface &&
                self.workspaceAnchorId == workspaceAnchorId &&
                self.surfaceAnchorId == surfaceAnchorId
        }
    }
}

enum CmuxNoteAttachmentTarget: Equatable, Sendable {
    case workspace(workspaceAnchorId: String)
    case surface(workspaceAnchorId: String, surfaceAnchorId: String, surfaceKind: String)

    var attachment: CmuxNoteAttachment {
        switch self {
        case .workspace(let workspaceAnchorId):
            return CmuxNoteAttachment(
                kind: .workspace,
                workspaceAnchorId: workspaceAnchorId,
                surfaceAnchorId: nil,
                surfaceKind: nil,
                createdAt: Date().timeIntervalSince1970
            )
        case .surface(let workspaceAnchorId, let surfaceAnchorId, let surfaceKind):
            return CmuxNoteAttachment(
                kind: .surface,
                workspaceAnchorId: workspaceAnchorId,
                surfaceAnchorId: surfaceAnchorId,
                surfaceKind: surfaceKind,
                createdAt: Date().timeIntervalSince1970
            )
        }
    }
}

struct CmuxNoteRecord: Codable, Equatable, Sendable {
    var id: String
    var slug: String
    var title: String
    var bodyPath: String
    var attachments: [CmuxNoteAttachment]
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
}

struct CmuxNoteStoreResult: Equatable, Sendable {
    var note: CmuxNoteRecord
    var path: String
    var created: Bool
    var attached: Bool
}

/// How a note relates to the surface/workspace context of a caller (e.g. the
/// terminal an agent runs `cmux note ...` from).
enum CmuxNoteContextLink: String, Codable, Sendable {
    case surface
    case workspace
}

/// Result of resolving "which note does this caller mean" from its
/// surface/workspace links. Drives context-aware `note list` ordering and the
/// `note here` resolver. See [[issue-4331-note-surface-type]].
struct CmuxNoteContextResolution: Sendable {
    /// Notes ordered for display: surface-linked first (most-recently-updated
    /// first within each group), then workspace-linked, then unlinked.
    var orderedNotes: [CmuxNoteRecord]
    /// Link classification keyed by note id (absent = not linked to caller).
    var linkByNoteId: [String: CmuxNoteContextLink]
    /// Best contextual match: most-recent surface-linked note, else
    /// most-recent workspace-linked note, else nil.
    var resolvedNoteId: String?

    func link(for note: CmuxNoteRecord) -> CmuxNoteContextLink? {
        linkByNoteId[note.id]
    }
}

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

struct CmuxNoteReadResult: Equatable, Sendable {
    var note: CmuxNoteRecord
    var path: String
    var content: String
}

struct CmuxNoteWriteResult: Equatable, Sendable {
    var note: CmuxNoteRecord
    var path: String
    var sizeBytes: Int64
}

enum CmuxNoteStoreError: Error, LocalizedError {
    case noteNotFound(slug: String)
    case corruptIndex(String)
    case untrustedNotesDirectory

    var errorDescription: String? {
        switch self {
        case .noteNotFound(let slug):
            return String(
                format: String(localized: "note.error.notFound", defaultValue: "Note not found: %@"),
                locale: .current,
                slug
            )
        case .corruptIndex(let detail):
            return String(
                format: String(localized: "note.error.corruptIndex", defaultValue: "Note index is invalid: %@"),
                locale: .current,
                detail
            )
        case .untrustedNotesDirectory:
            return String(
                localized: "note.error.untrustedNotesDirectory",
                defaultValue: "Notes are disabled for this project: .cmux/notes is a symlink."
            )
        }
    }
}

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
        }
    }
}

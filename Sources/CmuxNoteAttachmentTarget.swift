import Foundation

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

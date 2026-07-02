import Foundation

struct CmuxNoteAttachment: Codable, Equatable, Sendable {
    typealias Kind = CmuxNoteAttachmentKind

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

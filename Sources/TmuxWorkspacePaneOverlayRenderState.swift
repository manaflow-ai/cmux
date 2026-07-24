import CoreGraphics
import Foundation

struct TmuxWorkspacePaneOverlayRenderState: Equatable {
    let workspaceId: UUID
    let unreadRects: [CGRect]
    let flashRect: CGRect?
    let activePaneBorderRect: CGRect?
    let activePaneBorderColorHex: String?
    let flashToken: UInt64
    let flashReason: WorkspaceAttentionFlashReason?

    init(
        workspaceId: UUID,
        unreadRects: [CGRect],
        flashRect: CGRect?,
        activePaneBorderRect: CGRect? = nil,
        activePaneBorderColorHex: String? = nil,
        flashToken: UInt64,
        flashReason: WorkspaceAttentionFlashReason?
    ) {
        self.workspaceId = workspaceId
        self.unreadRects = unreadRects
        self.flashRect = flashRect
        self.activePaneBorderRect = activePaneBorderRect
        self.activePaneBorderColorHex = activePaneBorderColorHex
        self.flashToken = flashToken
        self.flashReason = flashReason
    }
}

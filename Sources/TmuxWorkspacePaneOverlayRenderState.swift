import CoreGraphics
import Foundation

struct TmuxWorkspacePaneOverlayRenderState: Equatable {
    let workspaceId: UUID
    let unreadRects: [CGRect]
    let flashRect: CGRect?
    let activePaneBorderRect: CGRect?
    let activePaneBorderColorHex: String?
    let focusMarkerRect: CGRect?
    let focusMarkerPaneID: UUID?
    let focusMarkerVisibility: String
    let focusMarkerDimRects: [CGRect]
    let focusMarkerStyle: String
    let focusMarkerColorHex: String?
    let focusMarkerThickness: Double
    let focusMarkerIntensity: Double
    let flashToken: UInt64
    let flashReason: WorkspaceAttentionFlashReason?
    private(set) var workspaceAttentionColor: WorkspaceAttentionColor

    init(
        workspaceId: UUID,
        unreadRects: [CGRect],
        flashRect: CGRect?,
        activePaneBorderRect: CGRect? = nil,
        activePaneBorderColorHex: String? = nil,
        focusMarkerRect: CGRect? = nil,
        focusMarkerPaneID: UUID? = nil,
        focusMarkerVisibility: String = "persistent",
        focusMarkerDimRects: [CGRect] = [],
        focusMarkerStyle: String = "none",
        focusMarkerColorHex: String? = nil,
        focusMarkerThickness: Double = 2,
        focusMarkerIntensity: Double = 0.24,
        flashToken: UInt64,
        flashReason: WorkspaceAttentionFlashReason?,
        workspaceAttentionColor: WorkspaceAttentionColor
    ) {
        self.workspaceId = workspaceId
        self.unreadRects = unreadRects
        self.flashRect = flashRect
        self.activePaneBorderRect = activePaneBorderRect
        self.activePaneBorderColorHex = activePaneBorderColorHex
        self.focusMarkerRect = focusMarkerRect
        self.focusMarkerPaneID = focusMarkerPaneID
        self.focusMarkerVisibility = focusMarkerVisibility
        self.focusMarkerDimRects = focusMarkerDimRects
        self.focusMarkerStyle = focusMarkerStyle
        self.focusMarkerColorHex = focusMarkerColorHex
        self.focusMarkerThickness = focusMarkerThickness
        self.focusMarkerIntensity = focusMarkerIntensity
        self.flashToken = flashToken
        self.flashReason = flashReason
        self.workspaceAttentionColor = workspaceAttentionColor
    }

    func replacingWorkspaceAttentionColor(with color: WorkspaceAttentionColor) -> Self {
        var copy = self
        copy.workspaceAttentionColor = color
        return copy
    }
}

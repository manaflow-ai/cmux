public import Foundation
public import CoreGraphics

/// Immutable snapshot describing how a workspace's tmux pane overlay should be
/// drawn for one render pass: the unread-indicator rects, an optional flash
/// rect, the flash token used to detect new flashes, and the flash reason.
public struct TmuxWorkspacePaneOverlayRenderState: Equatable, Sendable {
    /// The workspace this overlay state belongs to.
    public let workspaceId: UUID

    /// Rects (in overlay coordinates) that should show an unread indicator.
    public let unreadRects: [CGRect]

    /// The rect to flash, if any.
    public let flashRect: CGRect?

    /// Rect for the active pane border, if any (#7239).
    public let activePaneBorderRect: CGRect?

    /// Hex color for the active pane border, if any (#7239).
    public let activePaneBorderColorHex: String?

    /// Monotonic token that changes when a new flash should start.
    public let flashToken: UInt64

    /// Why the flash is occurring, if any.
    public let flashReason: WorkspaceAttentionFlashReason?

    /// Creates a tmux pane overlay render state snapshot.
    public init(
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

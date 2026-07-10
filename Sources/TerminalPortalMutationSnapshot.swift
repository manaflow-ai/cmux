import AppKit
import Bonsplit
import CmuxTerminal

struct TerminalPortalMutationSnapshot {
    let attachGeneration: Int
    let expectedSurfaceId: UUID
    let expectedSurfaceGeneration: UInt64
    let paneId: PaneID
    let isActive: Bool
    let isVisibleInUI: Bool
    let portalZPriority: Int
    let showsInactiveOverlay: Bool
    let showsUnreadNotificationRing: Bool
    let inactiveOverlayColor: NSColor
    let inactiveOverlayOpacity: CGFloat
    let searchState: TerminalSurface.SearchState?
    let paneDropZone: DropZone?
    let keyStateIndicatorText: String?
    let onFocus: ((UUID) -> Void)?
    let onTriggerFlash: (() -> Void)?
}

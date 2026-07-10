import AppKit
import Bonsplit
import CmuxTerminal

struct TerminalPortalMutationSnapshot {
    let attachGeneration: Int
    let expectedSurfaceId: UUID
    let expectedSurfaceGeneration: UInt64
    let paneId: PaneID
    let ownershipGeneration: UInt64
    let portalPresentation: @MainActor () -> TerminalPortalPresentation
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

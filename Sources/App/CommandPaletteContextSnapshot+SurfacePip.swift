import CmuxCommandPalette
import Foundation

extension CommandPaletteContextSnapshot {
    @MainActor
    mutating func setSurfacePipContext(panelId: UUID) {
        setBool(CommandPaletteContextKeys.panelCanPopOutPictureInPicture, AppDelegate.shared?.canPopOutSurfacePip(panelId: panelId) ?? false)
        setBool(CommandPaletteContextKeys.panelIsInPictureInPicture, AppDelegate.shared?.isSurfaceInPip(panelId: panelId) ?? false)
    }
}

import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings

/// Where the window's picture lies (`appearance.backgroundPlacement`, Leo 2026-11-22: "we also want
/// people to be able to reposition the images easily. the fast-actions need to be most accessible."):
/// Adjust Background… (drag, zoom, Fill, Fit, Center, Reset, Done: ``BackdropAdjustOverlay``) and the
/// one-step Background: Fill Window and Background: Fit Window. Each applies to `DesignSettings` at
/// once and writes the setting once.
enum BackgroundPlacementHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("appearance.adjustBackground", run: { _ in
            try AppearanceHandlers.requireUnmanaged(BackdropPlacementSetting.placementPath, context)
            let backdrop = try shownBackdrop()
            guard BackdropAdjustOverlay.begin(on: backdrop, onDone: { id, placement in save(placement, for: id, context) }) != nil else {
                throw ActionFailure.invalidTarget(BackdropAdjustOverlay.noPictureText)
            }
        })
        registry.bind("appearance.background.fill", run: { _ in try place(.fill, context) })
        registry.bind("appearance.background.fit", run: { _ in try place(.fit, context) })
    }

    /// Sets the shown picture's mode, keeping where it is anchored; the zoom goes back to 1.
    private static func place(_ mode: BackdropPlacement.Mode, _ context: AppActionContext) throws {
        try AppearanceHandlers.requireUnmanaged(BackdropPlacementSetting.placementPath, context)
        let backdrop = try shownBackdrop()
        guard let id = backdrop.placementPictureID else { throw ActionFailure.invalidTarget(BackdropAdjustOverlay.noPictureText) }
        let current = backdrop.placement ?? .centeredFill
        save(BackdropPlacement(mode: mode, x: current.x, y: current.y), for: id, context)
    }

    private static func shownBackdrop() throws -> WindowMaterialView {
        guard let backdrop = WindowMaterialView.backdrop(of: NSApp.keyWindow ?? NSApp.mainWindow) else {
            throw ActionFailure.invalidTarget(BackdropAdjustOverlay.noPictureText)
        }
        return backdrop
    }

    private static func save(_ placement: BackdropPlacement, for id: String, _ context: AppActionContext) {
        let value = BackdropPlacementSetting.value(context.design.backgroundPlacements, setting: id, to: placement)
        var next = context.design.backgroundPlacements
        next[id] = placement.isCenteredFill ? nil : placement
        context.design.backgroundPlacements = next
        context.writeSetting("place background", BackdropPlacementSetting.placementPath, value, reloadOnFailure: true)
    }
}

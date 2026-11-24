import AppKit
public import CmuxNextActions
public import CmuxNextDesign

extension BackdropPlacementSetting {
    /// Where the window's picture lies (`appearance.backgroundPlacement`, Leo 2026-11-22: "we also want
    /// people to be able to reposition the images easily. the fast-actions need to be most accessible."):
    /// Adjust Background… (drag, zoom, Fill, Fit, Center, Reset, Done: ``BackdropAdjustOverlay``) and the
    /// one-step Background: Fill Window and Background: Fit Window, on the key window's picture. Each
    /// writes the setting once and shows it at once; a managed key refuses and changes nothing.
    @MainActor public static func bindActions(into registry: ActionRegistry, design: DesignSettings, save: @escaping SettingChoiceActions.Save) {
        registry.bindEffect("appearance.adjustBackground") { _ in
            guard let backdrop = shownBackdrop(), backdrop.placementPictureID != nil,
                  BackdropAdjustOverlay.begin(on: backdrop, onDone: { [weak registry] id, placement in
                      if let refusal = store(placement, for: id, design: design, save: save) { registry?.refuse(refusal) }
                  }) != nil else { return .refused(BackdropAdjustOverlay.noPictureText) }
            return .done
        }
        registry.bindEffect("appearance.background.fill") { _ in place(.fill, design: design, save: save) }
        registry.bindEffect("appearance.background.fit") { _ in place(.fit, design: design, save: save) }
    }

    /// Sets the shown picture's mode, keeping where it is anchored; the zoom goes back to 1.
    @MainActor static func place(_ mode: BackdropPlacement.Mode, design: DesignSettings, save: SettingChoiceActions.Save) -> ActionEffect {
        guard let backdrop = shownBackdrop(), let id = backdrop.placementPictureID else { return .refused(BackdropAdjustOverlay.noPictureText) }
        let current = backdrop.placement ?? .centeredFill
        if let refusal = store(BackdropPlacement(mode: mode, x: current.x, y: current.y), for: id, design: design, save: save) {
            return .refused(refusal)
        }
        return .done
    }

    /// Writes `placement` for picture `id` and shows it; the refusal when the key is managed.
    @MainActor static func store(_ placement: BackdropPlacement, for id: String, design: DesignSettings, save: SettingChoiceActions.Save) -> String? {
        if let refusal = save(placementPath, value(design.backgroundPlacements, setting: id, to: placement)) { return refusal }
        var next = design.backgroundPlacements
        next[id] = placement.isCenteredFill ? nil : placement
        design.backgroundPlacements = next
        return nil
    }

    @MainActor private static func shownBackdrop() -> WindowMaterialView? {
        WindowMaterialView.backdrop(of: NSApp.keyWindow ?? NSApp.mainWindow)
    }
}

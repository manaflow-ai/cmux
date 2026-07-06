public import Foundation

extension MobileShellComposite {
    /// Updates one iOS scene's foreground activity and returns true only for the app-level inactive-to-active transition.
    @discardableResult
    public func setSceneForegroundActive(_ isActive: Bool, sceneID: UUID) -> Bool {
        let wasForegroundActive = !foregroundActiveSceneIDs.isEmpty
        if isActive {
            foregroundActiveSceneIDs.insert(sceneID)
        } else {
            foregroundActiveSceneIDs.remove(sceneID)
        }
        let isForegroundActive = !foregroundActiveSceneIDs.isEmpty
        setAppForegroundActive(isForegroundActive)
        return !wasForegroundActive && isForegroundActive
    }
}

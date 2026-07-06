public import Foundation

extension MobileShellComposite {
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

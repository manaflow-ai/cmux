public import Foundation

extension MobileShellComposite {
    public func setSceneForegroundActive(_ isActive: Bool, sceneID: UUID) {
        if isActive {
            foregroundActiveSceneIDs.insert(sceneID)
        } else {
            foregroundActiveSceneIDs.remove(sceneID)
        }
        setAppForegroundActive(!foregroundActiveSceneIDs.isEmpty)
    }
}

@preconcurrency import Sparkle

/// The `SPUUpdater` the controller builds (``UpdateController/init(log:clock:settings:hostBundle:defaults:fileManager:isDevLikeBundle:isDisabledByPolicy:)``).
final class CmuxSPUUpdater: SPUUpdater {
    /// The controller's driver (set once, right after init).
    weak var hostDriver: UpdateDriver?
}

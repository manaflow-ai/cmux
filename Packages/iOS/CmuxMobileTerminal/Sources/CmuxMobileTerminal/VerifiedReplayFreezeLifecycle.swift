#if canImport(UIKit)
/// Surface ownership captured before an off-main frozen-frame copy. Installation
/// is valid only while the same attached surface still suppresses rendering.
nonisolated struct VerifiedReplayFreezeLifecycle: Equatable, Sendable {
    let surfaceGeneration: UInt64

    func canInstall(
        currentSurfaceGeneration: UInt64,
        isDismantled: Bool,
        hasWindow: Bool,
        renderSuppressed: Bool,
        taskCancelled: Bool
    ) -> Bool {
        surfaceGeneration == currentSurfaceGeneration
            && !isDismantled
            && hasWindow
            && renderSuppressed
            && !taskCancelled
    }
}
#endif

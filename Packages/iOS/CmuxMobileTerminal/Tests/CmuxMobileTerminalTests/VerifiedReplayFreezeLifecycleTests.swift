#if canImport(UIKit)
import Testing
@testable import CmuxMobileTerminal

@Test("a detached or superseded surface cannot install an off-main frozen copy")
func verifiedReplayFreezeRequiresCurrentAttachedLifecycle() {
    let lifecycle = VerifiedReplayFreezeLifecycle(surfaceGeneration: 7)

    #expect(lifecycle.canInstall(
        currentSurfaceGeneration: 7,
        isDismantled: false,
        hasWindow: true,
        renderSuppressed: true,
        taskCancelled: false
    ))
    #expect(!lifecycle.canInstall(
        currentSurfaceGeneration: 8,
        isDismantled: false,
        hasWindow: true,
        renderSuppressed: true,
        taskCancelled: false
    ))
    #expect(!lifecycle.canInstall(
        currentSurfaceGeneration: 7,
        isDismantled: true,
        hasWindow: false,
        renderSuppressed: false,
        taskCancelled: true
    ))
}
#endif

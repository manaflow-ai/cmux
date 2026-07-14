#if canImport(UIKit)
import CMUXMobileCore
import QuartzCore

/// One verified replay readback and synchronous presentation awaiting completion.
nonisolated struct PendingVerifiedReplayPresentation {
    let id: UInt64
    let startedAt: CFTimeInterval
    let fence: VerifiedReplayPresentationFence
    var observedFrame: MobileTerminalRenderGridFrame?
    var renderSubmitted: Bool
    let continuation: CheckedContinuation<MobileTerminalRenderGridFrame?, Never>
}
#endif

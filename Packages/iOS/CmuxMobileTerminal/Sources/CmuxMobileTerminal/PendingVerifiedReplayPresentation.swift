#if canImport(UIKit)
import CMUXMobileCore
import QuartzCore

/// Successful presentation of one exact tokened Ghostty render. A drain render
/// has no observed frame; a replay render carries its local grid readback.
nonisolated struct VerifiedReplayPresentedSubmission: Sendable {
    let observedFrame: MobileTerminalRenderGridFrame?
}

/// One verified replay readback and tokened presentation awaiting completion.
nonisolated struct PendingVerifiedReplayPresentation {
    let id: UInt64
    let startedAt: CFTimeInterval
    var fence: VerifiedReplayPresentationFence
    var observedFrame: MobileTerminalRenderGridFrame?
    let continuation: CheckedContinuation<VerifiedReplayPresentedSubmission?, Never>
}
#endif

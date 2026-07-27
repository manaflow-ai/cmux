#if canImport(UIKit)
import CMUXMobileCore
import GhosttyKit
import QuartzCore

struct VerifiedReplayFrozenPresentation {
    let layer: CALayer
    let backgroundLayer: CALayer
    let contentLayer: CALayer?
    let cursorLayer: CALayer?
    let image: CGImage?
    let viewportRect: CGRect
}

/// Successful presentation of one exact tokened Ghostty render target and its
/// geometry. A drain render has no observed frame; a replay render carries its
/// local serialized grid readback. Pixel contents outside that grid contract
/// are not independently rerasterized by this proof.
nonisolated struct VerifiedReplayPresentedSubmission: Sendable {
    let observedFrame: MobileTerminalRenderGridFrame?
}

/// One verified replay readback and tokened presentation awaiting completion.
nonisolated struct PendingVerifiedReplayPresentation: @unchecked Sendable {
    var id: UInt64
    var startedAt: CFTimeInterval
    let surface: ghostty_surface_t
    let generation: UInt64
    let read: VerifiedReplaySurfaceRead?
    var fence: VerifiedReplayPresentationFence
    var observedFrame: MobileTerminalRenderGridFrame?
    let continuation: CheckedContinuation<VerifiedReplayPresentedSubmission?, Never>
}
#endif

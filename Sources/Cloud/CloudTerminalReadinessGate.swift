import Foundation

/// Pure ordering fence for one terminal presentation generation.
///
/// Replay and rendering can arrive in either order around reconnects. The gate
/// only opens when attachment state is true, replay has been applied through the
/// caller's condition, and a frame newer than the generation baseline has been
/// presented. It is small enough to exercise without constructing Ghostty.
struct CloudTerminalReadinessGate: Equatable, Sendable {
    private(set) var baselineFrame: UInt64 = 0
    private(set) var firstPresentedFrame: UInt64? = nil

    mutating func begin(baselineFrame: UInt64) {
        self.baselineFrame = baselineFrame
        firstPresentedFrame = nil
    }

    mutating func check(
        attachmentReady: Bool,
        rendererPresented: Bool,
        frameSequence: UInt64
    ) -> Bool {
        guard firstPresentedFrame == nil,
              attachmentReady,
              rendererPresented,
              frameSequence > baselineFrame else { return false }
        firstPresentedFrame = frameSequence
        return true
    }
}

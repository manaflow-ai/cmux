import AppKit
import QuartzCore
import Testing
@testable import MessagesLabHome

/// cx-sya4n: nothing loops under Reduce Motion. The view observes no notification: after the
/// setting changes (the system's, or the host's pin `MessagesLabHomeView.reduceMotionOverride`),
/// the host calls `applyReduceMotion()`, and a typing row already running in the view stills its
/// dots and stops its breath before that call returns.
@MainActor
@Suite(.serialized)
struct HomeApplyReduceMotionTests {
    /// Whether `layer` or a layer under it runs a repeating animation.
    private static func loops(_ layer: CALayer) -> Bool {
        let own = (layer.animationKeys() ?? []).contains { key in
            guard let animation = layer.animation(forKey: key) else { return false }
            if animation.repeatCount >= .greatestFiniteMagnitude || animation.repeatDuration > 0 { return true }
            return ((animation as? CAAnimationGroup)?.animations ?? []).contains {
                $0.repeatCount >= .greatestFiniteMagnitude || $0.repeatDuration > 0
            }
        }
        return own || (layer.sublayers ?? []).contains(where: loops)
    }

    @Test func applyReduceMotionStillsATypingRowAlreadyRunningInTheView() async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        defer { MessagesLabHomeView.reduceMotionOverride = nil }
        // From here to the last check nothing awaits, so no other suite's pin change (they all
        // run on the main actor) lands in between.
        MessagesLabHomeView.reduceMotionOverride = false
        // A typing row in the view's layer tree, as the transcript shows one.
        let cell = RowCell(frame: CGRect(x: 0, y: 0, width: 400, height: 40))
        let host = try #require(rig.view.layer)
        host.addSublayer(cell.layer)
        cell.startTypingDots(begin: CACurrentMediaTime())
        cell.startTypingBreath(insert: CACurrentMediaTime())
        let typing = cell.dots + cell.typingDiscs + [cell.typingContainer, cell.typingClip]
        let before = typing.contains(where: Self.loops)
        #expect(before, "the typing row should loop before Reduce Motion")

        MessagesLabHomeView.reduceMotionOverride = true
        rig.view.applyReduceMotion()
        let after = typing.contains(where: Self.loops)
        #expect(!after, "the typing row keeps looping after the host applied Reduce Motion")
    }
}

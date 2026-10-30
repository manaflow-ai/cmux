import AppKit
@testable import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// The native Home typing indicator is the Messages bubble with three staggered pulsing dots.
/// Reduce Motion and the host's Home motion gate hold it still; typing end and reuse stop it.
@MainActor
@Suite(.serialized) struct TypingDotsTests {
    @Test func nativeHomeShowsPulsingDotsAndHoldsThemStillWithoutMotion() async throws {
        let savedGate = MessagesLabHomeView.voiceMotionGate
        defer { MessagesLabHomeView.voiceMotionGate = savedGate }
        MessagesLabHomeView.voiceMotionGate = { true }
        let saved = MessagesLabHomeView.reduceMotionOverride
        MessagesLabHomeView.reduceMotionOverride = false
        defer { MessagesLabHomeView.reduceMotionOverride = saved }
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        rig.store.handle(.typing(HomeChatRig.conversation, rig.chief, on: true))
        rig.frame()
        let demo = try #require(rig.view.controller.demo)
        let row = try #require(demo.collection.visibleCells.compactMap { $0 as? RowCell }.first {
            if case .typing? = $0.spec?.kind { return true }; return false
        })
        let dots = row.typingContainer.sublayers?.filter { $0.cornerRadius == 3.25 } ?? []
        #expect(dots.count == 3, "The typing bubble holds three dots")
        #expect(row.typingContainer.sublayers?.contains { $0 is CAShapeLayer } != true, "No spinner arc")
        #expect(dotLoops(row) == 3, "Each dot pulses on the render server")

        MessagesLabHomeView.reduceMotionOverride = true
        #expect(loopPaths(in: row.layer).isEmpty, "Reduce Motion: nothing loops")
        #expect(row.typingContainer.sublayers?.filter { $0.cornerRadius == 3.25 }.count == 3, "The dots stay, still")
        MessagesLabHomeView.reduceMotionOverride = false
        #expect(dotLoops(row) == 3)
        MessagesLabHomeView.voiceMotionGate = { false }
        rig.view.applyReduceMotion()
        #expect(loopPaths(in: row.layer).isEmpty, "Animations off: nothing loops")
        MessagesLabHomeView.voiceMotionGate = { true }
        rig.view.applyReduceMotion()
        #expect(dotLoops(row) == 3)

        rig.store.handle(.typing(HomeChatRig.conversation, rig.chief, on: false))
        rig.frame()
        row.prepareForReuse()
        #expect(loopPaths(in: row.layer).isEmpty, "A recycled row keeps no loop")
    }

    private func dotLoops(_ row: RowCell) -> Int {
        (row.typingContainer.sublayers ?? []).filter { $0.sublayers?.first?.animation(forKey: "dots")?.repeatCount == .infinity }.count
    }

    private func loopPaths(in layer: CALayer) -> [String] {
        let own = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }.flatMap { loopPaths(in: $0) }
        return own + ((layer.sublayers ?? []) + [layer.mask].compactMap { $0 }).flatMap { loopPaths(in: $0) }
    }

    private func loopPaths(in animation: CAAnimation, repeating: Bool = false) -> [String] {
        let repeats = repeating || animation.repeatCount >= .greatestFiniteMagnitude
            || animation.repeatDuration >= .greatestFiniteMagnitude
        if let group = animation as? CAAnimationGroup {
            return (group.animations ?? []).flatMap { loopPaths(in: $0, repeating: repeats) }
        }
        guard repeats else { return [] }
        return [(animation as? CAPropertyAnimation)?.keyPath ?? "unknown"]
    }
}

import AppKit
@testable import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// The native Home used by the app must satisfy the shared renderer's no-pulse contract.
@MainActor
@Suite(.serialized) struct NoBreathingDotTests {
    @Test func nativeHomeSpinsAndStopsOnReduceMotionAndTypingEnd() async throws {
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
        #expect(loopPaths(in: row.layer) == ["transform.rotation.z"])
        MessagesLabHomeView.reduceMotionOverride = true
        #expect(loopPaths(in: row.layer).isEmpty)
        MessagesLabHomeView.reduceMotionOverride = false
        #expect(loopPaths(in: row.layer) == ["transform.rotation.z"])
        MessagesLabHomeView.voiceMotionGate = { false }
        rig.view.applyReduceMotion()
        #expect(loopPaths(in: row.layer).isEmpty)
        MessagesLabHomeView.voiceMotionGate = { true }
        rig.view.applyReduceMotion()
        #expect(loopPaths(in: row.layer) == ["transform.rotation.z"])
        rig.store.handle(.typing(HomeChatRig.conversation, rig.chief, on: false))
        rig.frame()
        #expect(loopPaths(in: row.layer).isEmpty, "The fading typing row must no longer loop")
        row.prepareForReuse()
        #expect(loopPaths(in: row.layer).isEmpty)
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

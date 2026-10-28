import QuartzCore
import Testing
@testable import CmuxHomeRender

/// Home joins the sidebar and tab NoBreathingDotTests: working means a spinner,
/// never a repeating opacity or scale animation, including in the typing bubble.
@MainActor
@Suite struct NoBreathingDotTests {
    @Test func typingSpinsAndStopsWhenTypingEnds() throws {
        let controller = Fixtures.controller()
        controller.update(items: [], summary: Fixtures.summary(), typing: [Fixtures.chief], hasOlder: false)
        let row = try #require(controller.scene.visible.values.first { $0.spec?.kind == .typing })
        #expect(loopPaths(in: row.layer) == ["transform.rotation.z"])
        let spinner = try #require(row.typingContainer.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        #expect(spinner.path != nil && spinner.strokeColor != nil && spinner.fillColor == nil)
        #expect(spinner.opacity == 1 && !spinner.isHidden)

        controller.update(items: [], summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(loopPaths(in: row.layer).isEmpty, "Typing ending must stop the loop, even during the exit transition")
    }

    @Test func motionSettingsStopAndResumeOnlyRotation() throws {
        let controller = Fixtures.controller()
        controller.update(items: [], summary: Fixtures.summary(), typing: [Fixtures.chief], hasOlder: false)
        let row = try #require(controller.scene.visible.values.first { $0.spec?.kind == .typing })
        controller.reduceMotion = true
        #expect(loopPaths(in: row.layer).isEmpty)
        controller.reduceMotion = false
        #expect(loopPaths(in: row.layer) == ["transform.rotation.z"])
        controller.animationSpeed = .off
        #expect(loopPaths(in: row.layer).isEmpty)
        controller.animationSpeed = .fast
        #expect(loopPaths(in: row.layer) == ["transform.rotation.z"])
        row.prepareForReuse()
        #expect(loopPaths(in: row.layer).isEmpty, "A recycled row must retain no repeating animation")
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

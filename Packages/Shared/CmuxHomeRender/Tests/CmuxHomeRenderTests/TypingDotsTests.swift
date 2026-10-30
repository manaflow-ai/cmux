import QuartzCore
import Testing
@testable import CmuxHomeRender

/// Home's typing indicator is the Messages bubble with three staggered dots.
/// The dots pulse on the render server only while motion is allowed and stop
/// when typing ends or the row is recycled; Reduce Motion leaves them still.
@MainActor
@Suite struct TypingDotsTests {
    @Test func typingShowsThreeStaggeredDotsAndStopsWhenTypingEnds() throws {
        let controller = Fixtures.controller()
        controller.update(items: [], summary: Fixtures.summary(), typing: [Fixtures.chief], hasOlder: false)
        let row = try #require(controller.scene.visible.values.first { $0.spec?.kind == .typing })
        let dots = (row.typingContainer.sublayers ?? []).filter { $0.cornerRadius == 3.25 }
        #expect(dots.count == 3, "The typing bubble holds three dots")
        #expect(dots.allSatisfy { $0.backgroundColor != nil && $0.cornerRadius > 0 && !$0.isHidden })
        #expect(row.typingContainer.sublayers?.contains { $0 is CAShapeLayer } != true, "No spinner arc in the typing bubble")
        #expect(loopPaths(in: row.layer) == ["opacity", "opacity", "opacity"])
        let phases = dots.compactMap { dot -> NSNumber? in
            (dot.sublayers?.first?.animation(forKey: "dots") as? CAKeyframeAnimation)?.values?.first as? NSNumber
        }
        #expect(Set(phases.map(\.doubleValue)).count == 3, "Each dot pulses at its own phase")

        controller.update(items: [], summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(loopPaths(in: row.layer).isEmpty, "Typing ending must stop the dots, even during the exit transition")
    }

    @Test func motionSettingsHoldTheDotsStill() throws {
        let controller = Fixtures.controller()
        controller.update(items: [], summary: Fixtures.summary(), typing: [Fixtures.chief], hasOlder: false)
        let row = try #require(controller.scene.visible.values.first { $0.spec?.kind == .typing })
        controller.reduceMotion = true
        #expect(loopPaths(in: row.layer).isEmpty)
        #expect(row.typingContainer.sublayers?.filter { $0.cornerRadius == 3.25 }.count == 3, "Reduce Motion keeps the dots, still")
        controller.reduceMotion = false
        #expect(loopPaths(in: row.layer) == ["opacity", "opacity", "opacity"])
        controller.animationSpeed = .off
        #expect(loopPaths(in: row.layer).isEmpty)
        controller.animationSpeed = .fast
        #expect(loopPaths(in: row.layer) == ["opacity", "opacity", "opacity"])
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

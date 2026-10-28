import QuartzCore
import Testing
@testable import CmuxHomeRender

/// The Chief's typing indicator is the Messages typing bubble with its three dots, never a spinner.
/// Leo, 2026-10-28: "Nobody asked for the fucking spinner to be propagated all throughout."
@MainActor
@Suite struct ChiefTypingBubbleTests {
    @Test func typingShowsThreeDotsAndNoSpinner() throws {
        let controller = Fixtures.controller()
        controller.update(items: [], summary: Fixtures.summary(), typing: [Fixtures.chief], hasOlder: false)
        let row = try #require(controller.scene.visible.values.first { $0.spec?.kind == .typing })
        #expect(!row.typingContainer.isHidden)
        let sublayers = row.typingContainer.sublayers ?? []
        #expect(!sublayers.contains { $0 is CAShapeLayer }, "The typing bubble draws no spinner arc")
        let dots = sublayers.filter { $0.cornerRadius == 3.25 && $0.bounds.width == 6.5 }
        #expect(dots.count == 3)
        #expect(!rotationLoops(in: row.layer), "Nothing in the typing row rotates")
    }

    private func rotationLoops(in layer: CALayer) -> Bool {
        let own = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }.contains(where: rotates)
        return own || (layer.sublayers ?? []).contains(where: rotationLoops)
    }

    private func rotates(_ animation: CAAnimation) -> Bool {
        if let group = animation as? CAAnimationGroup { return (group.animations ?? []).contains(where: rotates) }
        return ((animation as? CAPropertyAnimation)?.keyPath ?? "").hasPrefix("transform.rotation")
    }
}
